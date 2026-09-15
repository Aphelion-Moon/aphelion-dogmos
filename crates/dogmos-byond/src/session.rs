//! Owns the service child, request worker and bounded diagnostic capture.
//!
//! After a shutdown acknowledgement, allow one second for the service to release
//! state and exit, then terminate/reap the exact owned child. Diagnostic reads poll
//! without waiting for EOF; close cooperatively stops and joins the reader after
//! draining at most 64 KiB. The last diagnostic remains bounded to 4 KiB.
//! Request cancellation shuts down the Unix socket or cancels Windows pipe I/O.
//! Workers are joined, including after health observation has already reaped the
//! child. These are measured normal/fault cleanup bounds, not an unconditional
//! wall-time guarantee: OS termination/reaping or failed OS cancellation can still
//! delay final ownership cleanup. No worker is silently detached to meet a deadline.

use crate::session_limits::{
	SESSION_CONTROL_PAYLOAD_BYTES, SESSION_PENDING_CAPACITY, SESSION_REQUEST_TIMEOUT,
};
use crate::{BoundedDogmosClient, ClientError, DogmosClient};
use dogmos_protocol::{
	BuildIdentity, CapacityLimits, HandshakePayload, OperationKind, DOGMOS_ABI_VERSION,
	DOGMOS_PROTOCOL_VERSION,
};
use std::{
	io::{self, Read, Write},
	path::Path,
	process::{Child, ChildStderr, Command, Stdio},
	sync::{
		atomic::{AtomicBool, Ordering},
		Arc, Condvar, Mutex,
	},
	thread::{self, JoinHandle},
	time::{Duration, Instant},
};

const REQUEST_WORKER_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(1);
const SERVICE_DIAGNOSTIC_WAIT: Duration = Duration::from_millis(50);
const MAX_SERVICE_DIAGNOSTIC_BYTES: usize = 4096;
/// A shutdown acknowledgement is not process exit. Escalate after this grace period.
const SERVICE_EXIT_GRACE: Duration = Duration::from_secs(1);
const DIAGNOSTIC_POLL_INTERVAL: Duration = Duration::from_millis(5);
const MAX_DIAGNOSTIC_CLOSE_DRAIN_BYTES: usize = 64 * 1024;

/// Only nonblocking readers may be owned by the diagnostic worker. It is the sole
/// reader of the child pipe, so bytes reported ready cannot be consumed elsewhere.
trait DiagnosticReader: Send + 'static {
	fn read_available(&mut self, bytes: &mut [u8]) -> io::Result<usize>;
}

#[cfg(unix)]
impl DiagnosticReader for ChildStderr {
	fn read_available(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
		use std::os::fd::AsRawFd;
		let mut descriptor = libc::pollfd {
			fd: self.as_raw_fd(),
			events: libc::POLLIN,
			revents: 0,
		};
		// SAFETY: descriptor is initialized and writable; zero timeout never waits.
		match unsafe { libc::poll(&mut descriptor, 1, 0) } {
			-1 => Err(io::Error::last_os_error()),
			0 => Err(io::ErrorKind::WouldBlock.into()),
			_ => self.read(bytes), // readiness or hangup: data/EOF, with no competing reader.
		}
	}
}

#[cfg(windows)]
impl DiagnosticReader for ChildStderr {
	fn read_available(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
		use std::os::windows::io::AsRawHandle;
		use windows_sys::Win32::{Foundation::ERROR_BROKEN_PIPE, System::Pipes::PeekNamedPipe};
		let mut available = 0;
		// SAFETY: ChildStderr owns a live anonymous pipe; only available is written.
		if unsafe {
			PeekNamedPipe(
				self.as_raw_handle(),
				std::ptr::null_mut(),
				0,
				std::ptr::null_mut(),
				&mut available,
				std::ptr::null_mut(),
			)
		} == 0
		{
			let error = io::Error::last_os_error();
			return if error.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) {
				Ok(0)
			} else {
				Err(error)
			};
		}
		if available == 0 {
			return Err(io::ErrorKind::WouldBlock.into());
		}
		let count = bytes.len().min(available as usize);
		self.read(&mut bytes[..count])
	}
}

#[cfg(test)]
impl DiagnosticReader for io::Cursor<Vec<u8>> {
	fn read_available(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
		self.read(bytes)
	}
}

#[derive(Default)]
struct ServiceDiagnosticState {
	sequence: u64,
	latest: Option<String>,
}

struct ServiceDiagnosticCapture {
	state: Arc<(Mutex<ServiceDiagnosticState>, Condvar)>,
	worker: Option<JoinHandle<()>>,
	stop: Arc<AtomicBool>,
}

impl ServiceDiagnosticCapture {
	fn start(mut reader: impl DiagnosticReader) -> Self {
		let state = Arc::new((
			Mutex::new(ServiceDiagnosticState::default()),
			Condvar::new(),
		));
		let worker_state = Arc::clone(&state);
		let stop = Arc::new(AtomicBool::new(false));
		let worker_stop = Arc::clone(&stop);
		let worker = thread::spawn(move || {
			let mut read_buffer = [0_u8; 1024];
			let mut line = Vec::with_capacity(MAX_SERVICE_DIAGNOSTIC_BYTES);
			let mut close_drain_remaining = MAX_DIAGNOSTIC_CLOSE_DRAIN_BYTES;
			loop {
				let read = match reader.read_available(&mut read_buffer) {
					Ok(0) => {
						if !line.is_empty() {
							record_service_diagnostic(&worker_state, &line);
						}
						break;
					}
					Ok(read) => read,
					Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
						if worker_stop.load(Ordering::Acquire) {
							if !line.is_empty() {
								record_service_diagnostic(&worker_state, &line);
							}
							break;
						}
						thread::sleep(DIAGNOSTIC_POLL_INTERVAL);
						continue;
					}
					Err(error) if error.kind() == io::ErrorKind::Interrupted => {
						if worker_stop.load(Ordering::Acquire) {
							break;
						}
						continue;
					}
					Err(error) => {
						record_service_diagnostic(
							&worker_state,
							format!("dogmosd stderr read failed: {error}").as_bytes(),
						);
						break;
					}
				};
				for byte in &read_buffer[..read] {
					if *byte == b'\n' {
						if line.last() == Some(&b'\r') {
							line.pop();
						}
						if !line.is_empty() {
							record_service_diagnostic(&worker_state, &line);
						}
						line.clear();
					} else if line.len() < MAX_SERVICE_DIAGNOSTIC_BYTES {
						line.push(*byte);
					}
				}
				if worker_stop.load(Ordering::Acquire) {
					// Drain a bounded tail, even if an inherited writer keeps producing.
					close_drain_remaining = close_drain_remaining.saturating_sub(read);
					if close_drain_remaining == 0 {
						if !line.is_empty() {
							record_service_diagnostic(&worker_state, &line);
						}
						break;
					}
				}
			}
		});
		Self {
			state,
			worker: Some(worker),
			stop,
		}
	}

	fn sequence(&self) -> u64 {
		let (state, _) = &*self.state;
		state
			.lock()
			.unwrap_or_else(std::sync::PoisonError::into_inner)
			.sequence
	}

	fn latest_after(&self, sequence: u64, timeout: Duration) -> Option<String> {
		let (state, updated) = &*self.state;
		let locked = state
			.lock()
			.unwrap_or_else(std::sync::PoisonError::into_inner);
		let (locked, _) = updated
			.wait_timeout_while(locked, timeout, |state| state.sequence <= sequence)
			.unwrap_or_else(std::sync::PoisonError::into_inner);
		(sequence < locked.sequence)
			.then(|| locked.latest.clone())
			.flatten()
	}

	fn latest(&self) -> Option<String> {
		let (state, _) = &*self.state;
		state
			.lock()
			.unwrap_or_else(std::sync::PoisonError::into_inner)
			.latest
			.clone()
	}

	fn close(&mut self) {
		self.stop.store(true, Ordering::Release);
		if let Some(worker) = self.worker.take() {
			let _ = worker.join();
		}
	}
}

impl Drop for ServiceDiagnosticCapture {
	fn drop(&mut self) {
		self.close();
	}
}

fn record_service_diagnostic(state: &Arc<(Mutex<ServiceDiagnosticState>, Condvar)>, bytes: &[u8]) {
	let mut diagnostic = String::from_utf8_lossy(bytes).into_owned();
	if diagnostic.len() > MAX_SERVICE_DIAGNOSTIC_BYTES {
		let mut end = MAX_SERVICE_DIAGNOSTIC_BYTES;
		while !diagnostic.is_char_boundary(end) {
			end -= 1;
		}
		diagnostic.truncate(end);
	}
	let (state, updated) = &**state;
	let mut state = state
		.lock()
		.unwrap_or_else(std::sync::PoisonError::into_inner);
	state.sequence = state.sequence.saturating_add(1);
	state.latest = Some(diagnostic);
	updated.notify_all();
}

pub(crate) struct ServiceSession {
	pub(crate) client: BoundedDogmosClient,
	service: Child,
	diagnostics: ServiceDiagnosticCapture,
	reaped: bool,
	#[cfg(windows)]
	service_job: Option<std::os::windows::io::OwnedHandle>,
}

impl ServiceSession {
	pub(crate) fn request_with_response<T, E>(
		&mut self,
		operation: OperationKind,
		payload: &[u8],
		response_capacity: usize,
		decode: impl FnOnce(&[u8]) -> Result<T, E>,
	) -> Result<T, E>
	where
		E: From<ClientError>,
	{
		self.request_with_response_timeout(
			operation,
			payload,
			response_capacity,
			SESSION_REQUEST_TIMEOUT,
			decode,
		)
	}

	pub(crate) fn request_with_response_timeout<T, E>(
		&mut self,
		operation: OperationKind,
		payload: &[u8],
		response_capacity: usize,
		timeout: Duration,
		decode: impl FnOnce(&[u8]) -> Result<T, E>,
	) -> Result<T, E>
	where
		E: From<ClientError>,
	{
		let diagnostic_sequence = self.diagnostics.sequence();
		match self
			.client
			.round_trip(operation, payload, response_capacity, timeout)
		{
			Ok(response) => decode(response),
			Err(error @ (ClientError::RequestTimeout | ClientError::WorkerStopped)) => {
				let process_id = self.service.id();
				let process_state = self.terminate_service();
				Err(ClientError::ServiceProcess {
					source: Box::new(error),
					process_id,
					process_state,
					service_diagnostic: self.diagnostics.latest(),
				}
				.into())
			}
			Err(error @ ClientError::Server(_)) => {
				let diagnostic = self
					.diagnostics
					.latest_after(diagnostic_sequence, SERVICE_DIAGNOSTIC_WAIT);
				Err(self.with_process_context(error, diagnostic).into())
			}
			Err(error) => Err(error.into()),
		}
	}

	pub(crate) fn request_without_response(
		&mut self,
		operation: OperationKind,
		payload: &[u8],
	) -> Result<(), ClientError> {
		self.request_with_response(operation, payload, 0, |_| Ok(()))
	}

	fn terminate_service(&mut self) -> String {
		let cleanup_deadline = Instant::now() + REQUEST_WORKER_SHUTDOWN_TIMEOUT;
		#[cfg(windows)]
		self.service_job.take();
		let kill_result = self.service.kill();
		// Retain/reap the exact child. An OS that fails to complete termination cannot
		// provide an absolute wall-time guarantee; never detach ownership to fake one.
		let wait_result = self.service.wait();
		self.reaped = wait_result.is_ok();
		self.diagnostics.close();
		let process_state = match (kill_result, wait_result) {
			(_, Ok(status)) => format!("terminated ({status})"),
			(Err(error), Err(wait_error)) => {
				format!("termination failed ({error}); wait failed ({wait_error})")
			}
			(Ok(()), Err(error)) => format!("terminated; wait failed ({error})"),
		};
		match self
			.client
			.close(cleanup_deadline.saturating_duration_since(Instant::now()))
		{
			Ok(()) => process_state,
			Err(error) => format!("{process_state}; request worker close failed ({error})"),
		}
	}

	fn with_process_context(
		&mut self,
		error: ClientError,
		service_diagnostic: Option<String>,
	) -> ClientError {
		let process_id = self.service.id();
		let process_state = match self.service.try_wait() {
			Ok(Some(status)) => {
				self.reaped = true;
				format!("exited ({status})")
			}
			Ok(None) => "running".into(),
			Err(status_error) => format!("unavailable ({status_error})"),
		};
		ClientError::ServiceProcess {
			source: Box::new(error),
			process_id,
			process_state,
			service_diagnostic,
		}
	}

	pub(crate) fn is_healthy(&mut self) -> io::Result<bool> {
		if self.client.is_worker_finished() {
			return Ok(false);
		}
		match self.service.try_wait()? {
			Some(_) => {
				self.reaped = true;
				Ok(false)
			}
			None => Ok(true),
		}
	}

	pub(crate) fn shutdown(&mut self) -> eyre::Result<()> {
		if self.reaped {
			self.diagnostics.close();
			self.client.close(REQUEST_WORKER_SHUTDOWN_TIMEOUT)?;
			return Ok(());
		}
		if let Err(error) = self.request_without_response(OperationKind::Shutdown, &[]) {
			let cleanup = self.terminate_service();
			return Err(ClientError::ServiceProcess {
				source: Box::new(error),
				process_id: self.service.id(),
				process_state: cleanup,
				service_diagnostic: self.diagnostics.latest(),
			}
			.into());
		}
		let deadline = Instant::now() + SERVICE_EXIT_GRACE;
		loop {
			match self.service.try_wait() {
				Ok(Some(status)) => {
					self.reaped = true;
					self.diagnostics.close();
					self.client.close(REQUEST_WORKER_SHUTDOWN_TIMEOUT)?;
					if !status.success() {
						return Err(eyre::eyre!("dogmosd did not shut down cleanly ({status})"));
					}
					return Ok(());
				}
				Ok(None) if Instant::now() < deadline => thread::sleep(DIAGNOSTIC_POLL_INTERVAL),
				Ok(None) => {
					let cleanup = self.terminate_service();
					return Err(eyre::eyre!("dogmosd acknowledged shutdown but did not exit within {SERVICE_EXIT_GRACE:?}; {cleanup}"));
				}
				Err(error) => {
					let cleanup = self.terminate_service();
					return Err(eyre::Report::new(error).wrap_err(cleanup));
				}
			}
		}
	}
}

impl Drop for ServiceSession {
	fn drop(&mut self) {
		if !self.reaped {
			let _ = self.terminate_service();
		}
		self.diagnostics.close();
		if let Err(error) = self.client.close(REQUEST_WORKER_SHUTDOWN_TIMEOUT) {
			eprintln!("dogmosd session drop: request worker close failed ({error})");
		}
	}
}

pub(crate) fn start_service_session(service_path: &str) -> eyre::Result<ServiceSession> {
	let auth_token = system_auth_token()?;
	let service_digest = dogmos_identity::sha256_file(Path::new(service_path))?;
	let build_metadata = dogmos_identity::BuildMetadata::from_compile_environment()?;
	let endpoint = format!(
		"dogmos-byond-bench-{}-{}",
		std::process::id(),
		u64::from_le_bytes(auth_token[..8].try_into().unwrap()),
	);
	let handshake = HandshakePayload {
		auth_token,
		identity: BuildIdentity {
			abi_version: DOGMOS_ABI_VERSION,
			protocol_version: DOGMOS_PROTOCOL_VERSION,
			source_revision: build_metadata.source_revision,
			feature_fingerprint: build_metadata.feature_fingerprint,
			executable_digest: service_digest,
		},
		capacities: CapacityLimits {
			max_control_payload: SESSION_CONTROL_PAYLOAD_BYTES as u32,
			max_batch_operations: 4096,
			max_callback_events: SESSION_PENDING_CAPACITY,
			max_pending_continuations: SESSION_PENDING_CAPACITY,
			max_frontier_handles: 1_048_576,
			max_stage_work_items: 4096,
			max_reaction_transactions: SESSION_PENDING_CAPACITY,
			reserved: 0,
			max_world_bytes: 8 * 1024 * 1024 * 1024,
		},
		process_id: std::process::id(),
		world_generation: 1,
		world_nonce: u64::from_le_bytes(auth_token[8..16].try_into().unwrap()),
	};
	let mut command = Command::new(service_path);
	command
		.arg("--echo-server")
		.arg(&endpoint)
		.stdin(Stdio::piped())
		.stdout(Stdio::null())
		.stderr(Stdio::piped());
	configure_service_command(&mut command);
	let mut service = command.spawn()?;
	let stderr = service
		.stderr
		.take()
		.ok_or_else(|| eyre::eyre!("dogmosd stderr was not piped"))?;
	let mut diagnostics = ServiceDiagnosticCapture::start(stderr);
	#[cfg(windows)]
	let service_job = match attach_kill_on_close_job(&service) {
		Ok(job) => job,
		Err(error) => {
			let _ = service.kill();
			let _ = service.wait();
			diagnostics.close();
			return Err(error.into());
		}
	};
	if let Err(error) = service
		.stdin
		.take()
		.ok_or_else(|| eyre::eyre!("dogmosd stdin was not piped"))?
		.write_all(&handshake.encode())
	{
		let _ = service.kill();
		let _ = service.wait();
		diagnostics.close();
		return Err(error.into());
	}
	let client = match DogmosClient::connect(&endpoint, handshake, Duration::from_secs(5)) {
		Ok(client) => client,
		Err(error) => {
			let _ = service.kill();
			let _ = service.wait();
			diagnostics.close();
			return Err(error.into());
		}
	};
	let client = match BoundedDogmosClient::new(client) {
		Ok(client) => client,
		Err(error) => {
			let _ = service.kill();
			let _ = service.wait();
			diagnostics.close();
			return Err(error.into());
		}
	};
	Ok(ServiceSession {
		client,
		service,
		diagnostics,
		reaped: false,
		#[cfg(windows)]
		service_job: Some(service_job),
	})
}

#[cfg(windows)]
fn configure_service_command(command: &mut Command) {
	use std::os::windows::process::CommandExt;
	use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;

	command.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn configure_service_command(_command: &mut Command) {}

#[cfg(windows)]
fn attach_kill_on_close_job(service: &Child) -> io::Result<std::os::windows::io::OwnedHandle> {
	use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
	use windows_sys::Win32::System::JobObjects::{
		AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
		SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
		JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
	};

	// SAFETY: null security attributes and name request an unnamed job with the caller's default
	// security descriptor. The returned handle is checked before ownership is transferred.
	let raw_job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
	if raw_job.is_null() {
		return Err(io::Error::last_os_error());
	}
	// SAFETY: `raw_job` is a newly-created, non-null owned handle and is transferred exactly once.
	let job = unsafe { OwnedHandle::from_raw_handle(raw_job) };
	// SAFETY: this Windows structure is plain integer/pointer data whose documented default is all
	// zero before selecting the one limit flag used below.
	let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
	limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
	// SAFETY: `job` remains live for the call and `limits` points to a correctly-sized initialized
	// JOBOBJECT_EXTENDED_LIMIT_INFORMATION value.
	let configured = unsafe {
		SetInformationJobObject(
			job.as_raw_handle(),
			JobObjectExtendedLimitInformation,
			std::ptr::from_ref(&limits).cast(),
			std::mem::size_of_val(&limits) as u32,
		)
	};
	if configured == 0 {
		return Err(io::Error::last_os_error());
	}
	// SAFETY: both handles are live for the call; the child handle belongs to `service`, while the
	// job handle remains owned by the returned `OwnedHandle`.
	let assigned =
		unsafe { AssignProcessToJobObject(job.as_raw_handle(), service.as_raw_handle()) };
	if assigned == 0 {
		return Err(io::Error::last_os_error());
	}
	Ok(job)
}

#[cfg(windows)]
pub(crate) fn system_auth_token() -> eyre::Result<[u8; 32]> {
	use windows_sys::Win32::Security::Cryptography::{
		BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG,
	};

	let mut token = [0_u8; 32];
	// SAFETY: the null algorithm handle selects the system RNG, and `token` is a live writable
	// 32-byte buffer for the exact length passed to BCryptGenRandom.
	let status = unsafe {
		BCryptGenRandom(
			std::ptr::null_mut(),
			token.as_mut_ptr(),
			token.len() as u32,
			BCRYPT_USE_SYSTEM_PREFERRED_RNG,
		)
	};
	if status < 0 {
		return Err(eyre::eyre!(
			"BCryptGenRandom failed with NTSTATUS {status:#x}"
		));
	}
	Ok(token)
}

#[cfg(not(windows))]
pub(crate) fn system_auth_token() -> eyre::Result<[u8; 32]> {
	use std::{fs, io::Read};

	let mut token = [0_u8; 32];
	fs::File::open("/dev/urandom")?.read_exact(&mut token)?;
	Ok(token)
}

#[cfg(test)]
mod tests {
	use super::*;
	use super::{ServiceDiagnosticCapture, MAX_SERVICE_DIAGNOSTIC_BYTES};
	use dogmos_protocol::{read_frame_into, write_frame, HANDSHAKE_PAYLOAD_LEN};
	use interprocess::local_socket::{prelude::*, GenericNamespaced, ListenerOptions};
	use std::io::Cursor;
	use std::time::{Instant, SystemTime, UNIX_EPOCH};

	fn fixture_handshake() -> HandshakePayload {
		HandshakePayload {
			auth_token: [0x5a; 32],
			identity: BuildIdentity {
				abi_version: DOGMOS_ABI_VERSION,
				protocol_version: DOGMOS_PROTOCOL_VERSION,
				source_revision: [1; 20],
				feature_fingerprint: [2; 32],
				executable_digest: [3; 32],
			},
			capacities: CapacityLimits {
				max_control_payload: 4096,
				max_batch_operations: 16,
				max_callback_events: 16,
				max_pending_continuations: 16,
				max_frontier_handles: 16,
				max_stage_work_items: 16,
				max_reaction_transactions: 16,
				reserved: 0,
				max_world_bytes: 1024 * 1024,
			},
			process_id: std::process::id(),
			world_generation: 1,
			world_nonce: 42,
		}
	}

	/// Runs only in an explicitly spawned copy of the test executable.
	#[test]
	fn fault_service_child() {
		let Ok(mode) = std::env::var("DOGMOS_SESSION_FAULT_CHILD") else {
			return;
		};
		std::panic::set_hook(Box::new(|info| {
			eprintln!(
				"fixture child panic: {}",
				info.to_string().replace('\n', " | ")
			);
		}));
		if mode == "stderr-open" {
			eprintln!("fixture stderr remains open");
			thread::sleep(Duration::from_secs(2));
			return;
		}
		let endpoint = std::env::var("DOGMOS_SESSION_FAULT_ENDPOINT").unwrap();
		let listener = ListenerOptions::new()
			.name(endpoint.to_ns_name::<GenericNamespaced>().unwrap())
			.create_sync()
			.unwrap();
		let mut stream = listener.accept().unwrap();
		let mut payload = [0_u8; HANDSHAKE_PAYLOAD_LEN];
		let (request, size) = read_frame_into(&mut stream, &mut payload).unwrap();
		let mut handshake = HandshakePayload::decode(&payload[..size]).unwrap();
		handshake.process_id = std::process::id();
		write_frame(&mut stream, request.response(), &handshake.encode()).unwrap();
		let (request, _) = read_frame_into(&mut stream, &mut payload).unwrap();
		if mode == "abrupt" {
			eprintln!("fixture abrupt exit provenance");
			std::process::exit(17);
		}
		if mode == "stall" {
			eprintln!("fixture stalled request provenance");
			thread::sleep(Duration::from_secs(2));
			return;
		}
		assert_eq!(request.operation_kind().unwrap(), OperationKind::Shutdown);
		write_frame(&mut stream, request.response(), &[]).unwrap();
		if mode == "clean" {
			return;
		}
		eprintln!("fixture acknowledged shutdown without exiting");
		thread::sleep(Duration::from_secs(2));
	}

	/// Owns the child even when fixture connection or client setup panics.
	struct FixtureChild(Option<Child>);

	impl std::ops::Deref for FixtureChild {
		type Target = Child;
		fn deref(&self) -> &Child {
			self.0.as_ref().expect("fixture child already transferred")
		}
	}

	impl std::ops::DerefMut for FixtureChild {
		fn deref_mut(&mut self) -> &mut Child {
			self.0.as_mut().expect("fixture child already transferred")
		}
	}

	impl Drop for FixtureChild {
		fn drop(&mut self) {
			if let Some(child) = &mut self.0 {
				let _ = child.kill();
				let _ = child.wait();
			}
		}
	}

	fn spawn_fixture(mode: &str, endpoint: &str) -> FixtureChild {
		let mut command = Command::new(std::env::current_exe().unwrap());
		command
			.args([
				"--exact",
				"session::tests::fault_service_child",
				"--nocapture",
			])
			.env("DOGMOS_SESSION_FAULT_CHILD", mode)
			.env("DOGMOS_SESSION_FAULT_ENDPOINT", endpoint)
			.stdin(Stdio::null())
			.stdout(Stdio::null())
			.stderr(Stdio::piped());
		configure_service_command(&mut command);
		FixtureChild(Some(command.spawn().unwrap()))
	}

	#[test]
	fn diagnostic_close_does_not_wait_for_an_open_writer() {
		let mut child = spawn_fixture("stderr-open", "unused");
		let mut capture = ServiceDiagnosticCapture::start(child.stderr.take().unwrap());
		assert!(capture.latest_after(0, Duration::from_secs(1)).is_some());
		let started = Instant::now();
		capture.close();
		let elapsed = started.elapsed();
		eprintln!("held-writer diagnostic close: {elapsed:?}");
		let _ = child.kill();
		child.wait().unwrap();
		assert!(
			elapsed < Duration::from_millis(500),
			"diagnostic close waited {elapsed:?} for writer EOF"
		);
		assert!(capture.worker.is_none());
	}

	#[test]
	fn acknowledged_shutdown_requires_bounded_process_exit() {
		let mut session = fixture_session("ack-no-exit");
		let started = Instant::now();
		let result = session.shutdown();
		let elapsed = started.elapsed();
		eprintln!("acknowledgement without exit cleanup: {elapsed:?}");
		assert!(
			result
				.as_ref()
				.is_err_and(|error| error.to_string().contains("acknowledged shutdown")),
			"wrong shutdown result: {result:?}"
		);
		assert!(
			elapsed < SERVICE_EXIT_GRACE + Duration::from_secs(1),
			"shutdown took {elapsed:?}"
		);
		assert!(session.reaped);
		assert!(session.client.is_worker_finished());
		assert!(session.diagnostics.worker.is_none());
		assert!(session
			.diagnostics
			.latest()
			.unwrap()
			.contains("acknowledged shutdown"));
		session.shutdown().unwrap();
	}

	fn fixture_endpoint(timestamp_nanos: u128) -> String {
		// Wall-clock samples may repeat between concurrently starting fixtures.
		static NEXT_FIXTURE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
		let serial = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
		format!(
			"dogmos-session-{}-{timestamp_nanos}-{serial}",
			std::process::id()
		)
	}

	#[test]
	fn fixture_endpoints_remain_distinct_when_clock_does_not_advance() {
		assert_ne!(fixture_endpoint(42), fixture_endpoint(42));
	}

	fn fixture_session(mode: &str) -> ServiceSession {
		let endpoint = fixture_endpoint(
			SystemTime::now()
				.duration_since(UNIX_EPOCH)
				.unwrap()
				.as_nanos(),
		);
		eprintln!("fixture mode={mode} endpoint={endpoint}");
		let mut child = spawn_fixture(mode, &endpoint);
		let diagnostics = ServiceDiagnosticCapture::start(child.stderr.take().unwrap());
		#[cfg(windows)]
		let job = attach_kill_on_close_job(&child).unwrap();
		let client = DogmosClient::connect(&endpoint, fixture_handshake(), Duration::from_secs(2))
			.unwrap_or_else(|error| {
				panic!(
					"fixture mode={mode} endpoint={endpoint} connect failed: {error:?}; diagnostic={:?}",
					diagnostics.latest_after(0, SERVICE_DIAGNOSTIC_WAIT)
				)
			});
		let client = BoundedDogmosClient::new(client).unwrap();
		ServiceSession {
			client,
			service: child.0.take().unwrap(),
			diagnostics,
			reaped: false,
			#[cfg(windows)]
			service_job: Some(job),
		}
	}

	#[test]
	fn request_cancellation_finishes_worker_while_service_is_still_alive() {
		let mut session = fixture_session("stall");
		assert!(matches!(
			session.client.echo(b"stall", Duration::from_millis(25)),
			Err(ClientError::RequestTimeout)
		));
		let closed = session.client.close(Duration::from_millis(500));
		let alive = session.service.try_wait().unwrap().is_none();
		// Always reap the isolated child before an assertion can unwind.
		let cleanup = session.terminate_service();
		assert!(
			closed.is_ok(),
			"worker cancellation failed: {closed:?}; {cleanup}"
		);
		assert!(
			alive,
			"cancellation test must not rely on the service exiting"
		);
		assert!(session.client.is_worker_finished());
	}

	#[test]
	fn abrupt_death_preserves_error_diagnostics_and_reaps_workers() {
		let mut session = fixture_session("abrupt");
		let pid = session.service.id();
		let started = Instant::now();
		let result = session.shutdown().unwrap_err();
		assert!(started.elapsed() < Duration::from_millis(1500));
		assert!(
			result
				.chain()
				.any(|error| error.downcast_ref::<ClientError>().is_some()),
			"original client error lost: {result:?}; diagnostic={:?}",
			session.diagnostics.latest()
		);
		assert_eq!(session.service.id(), pid);
		assert!(session.reaped);
		assert!(session.client.is_worker_finished());
		assert!(session.diagnostics.worker.is_none());
		assert_eq!(
			session.diagnostics.latest().as_deref(),
			Some("fixture abrupt exit provenance")
		);
	}

	#[test]
	fn clean_shutdown_is_repeatable_and_releases_owned_workers() {
		let mut session = fixture_session("clean");
		session.shutdown().unwrap();
		session.shutdown().unwrap();
		assert!(session.reaped);
		assert!(session.client.is_worker_finished());
		assert!(session.diagnostics.worker.is_none());
	}

	#[test]
	fn health_reaped_process_still_closes_diagnostic_worker_on_drop() {
		let mut session = fixture_session("clean");
		session
			.client
			.round_trip(OperationKind::Shutdown, &[], 0, Duration::from_secs(1))
			.unwrap();
		let deadline = Instant::now() + Duration::from_secs(1);
		while !session.reaped && Instant::now() < deadline {
			let _ = session.is_healthy();
			thread::sleep(Duration::from_millis(5));
		}
		assert!(session.reaped);
		let stop = Arc::clone(&session.diagnostics.stop);
		drop(session);
		assert!(stop.load(Ordering::Acquire));
	}

	#[test]
	fn service_diagnostic_capture_keeps_only_the_last_complete_line() {
		let mut capture = ServiceDiagnosticCapture::start(Cursor::new(
			b"first diagnostic\nlast diagnostic\n\n".to_vec(),
		));
		capture.close();

		assert_eq!(capture.latest().as_deref(), Some("last diagnostic"));
	}

	#[test]
	fn service_diagnostic_capture_bounds_the_retained_line() {
		let mut line = vec![b'x'; MAX_SERVICE_DIAGNOSTIC_BYTES + 128];
		line.push(b'\n');
		let mut capture = ServiceDiagnosticCapture::start(Cursor::new(line));
		capture.close();

		assert_eq!(
			capture.latest().unwrap().len(),
			MAX_SERVICE_DIAGNOSTIC_BYTES
		);
	}
}
