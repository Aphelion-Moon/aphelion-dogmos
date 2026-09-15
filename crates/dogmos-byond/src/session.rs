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
//!
//! Startup owns child/diagnostics before fallible setup. The endpoint and handshake
//! share a connection budget; the handshake worker is cancelled and joined on expiry.
//! Windows releases its exact kill-on-close job on every terminal path. Unix creates
//! a child process group, observes exit with waitid(WNOWAIT), consumes the group before
//! reaping its leader, and never signals a stored PGID after identity could be reused.
//! Group containment excludes descendants deliberately leaving the group. Windows
//! attachment precedes delivery of dogmosd's blocking stdin handshake; it cannot
//! retroactively contain arbitrary children launched before job attachment.

#![deny(clippy::undocumented_unsafe_blocks)]

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

/// Containment is consumed before the owned leader is reaped. A Unix PGID is never
/// retained after wait: once empty and reaped, the numeric ID could be reused.
#[derive(Default)]
struct ServiceContainment {
	#[cfg(windows)]
	job: Option<std::os::windows::io::OwnedHandle>,
	#[cfg(unix)]
	group: Option<libc::pid_t>,
}

impl ServiceContainment {
	fn attach(service: &Child) -> io::Result<Self> {
		#[cfg(windows)]
		{
			Ok(Self {
				job: Some(attach_kill_on_close_job(service)?),
			})
		}
		#[cfg(unix)]
		{
			Ok(Self {
				group: Some(service.id() as libc::pid_t),
			})
		}
	}

	fn release(&mut self) -> io::Result<()> {
		#[cfg(windows)]
		{
			self.job.take();
		}
		#[cfg(unix)]
		{
			if let Some(group) = self.group.take() {
				// SAFETY: process_group(0) created this exact owned child's group. The
				// leader has not been reaped, so its numeric identity cannot be reused.
				if unsafe { libc::kill(-group, libc::SIGKILL) } != 0 {
					let error = io::Error::last_os_error();
					if error.raw_os_error() != Some(libc::ESRCH) {
						return Err(error);
					}
				}
			}
		}
		Ok(())
	}

	fn observe_exit(&mut self, child: &mut Child) -> io::Result<Option<std::process::ExitStatus>> {
		#[cfg(unix)]
		{
			if self.group.is_some() {
				// SAFETY: siginfo_t is zero-initialized output; WNOWAIT observes only
				// our owned child without releasing its PID/process-group identity.
				let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
				// SAFETY: child remains unreaped and info is valid writable output.
				let result = unsafe {
					libc::waitid(
						libc::P_PID,
						child.id(),
						&mut info,
						libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
					)
				};
				if result != 0 {
					return Err(io::Error::last_os_error());
				}
				// SAFETY: waitid initialized the SIGCHLD variant of siginfo_t.
				if unsafe { info.si_pid() } == 0 {
					return Ok(None);
				}
				self.release()?;
				return child.wait().map(Some);
			}
		}
		let status = child.try_wait()?;
		if status.is_some() {
			self.release()?;
		}
		Ok(status)
	}
}

fn terminate_owned_service(
	service: &mut Child,
	containment: &mut ServiceContainment,
) -> (bool, String) {
	let group = containment.release();
	let kill = service.kill();
	// OS termination/reaping may still block; retaining ownership is deliberate.
	let wait = service.wait();
	let reaped = wait.is_ok();
	let mut state = match (kill, wait) {
		(_, Ok(status)) => format!("terminated ({status})"),
		(Err(kill), Err(wait)) => format!("termination failed ({kill}); wait failed ({wait})"),
		(Ok(()), Err(wait)) => format!("terminated; wait failed ({wait})"),
	};
	if let Err(error) = group {
		state.push_str(&format!("; containment cleanup failed ({error})"));
	}
	(reaped, state)
}

pub(crate) struct ServiceSession {
	pub(crate) client: BoundedDogmosClient,
	service: Child,
	diagnostics: ServiceDiagnosticCapture,
	reaped: bool,
	containment: ServiceContainment,
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
		let (reaped, process_state) =
			terminate_owned_service(&mut self.service, &mut self.containment);
		self.reaped = reaped;
		self.diagnostics.close();
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
		let process_state = match self.containment.observe_exit(&mut self.service) {
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
		match self.containment.observe_exit(&mut self.service)? {
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
			match self.containment.observe_exit(&mut self.service) {
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
	start_spawned_service(
		command.spawn()?,
		&endpoint,
		handshake,
		Duration::from_secs(5),
	)
}

/// Owns every partially initialized resource before any fallible setup step.
struct StartingService {
	service: Option<Child>,
	diagnostics: Option<ServiceDiagnosticCapture>,
	reaped: bool,
	containment: ServiceContainment,
}

impl StartingService {
	fn cleanup(&mut self) -> String {
		let Some(service) = &mut self.service else {
			return "transferred".into();
		};
		let (reaped, state) = terminate_owned_service(service, &mut self.containment);
		self.reaped = reaped;
		if let Some(diagnostics) = &mut self.diagnostics {
			diagnostics.close();
		}
		state
	}
}

impl Drop for StartingService {
	fn drop(&mut self) {
		if self.service.is_some() && !self.reaped {
			let _ = self.cleanup();
		}
	}
}

/// Concrete startup seam shared by the real command and isolated partial-init fixtures.
fn start_spawned_service(
	service: Child,
	endpoint: &str,
	handshake: HandshakePayload,
	timeout: Duration,
) -> eyre::Result<ServiceSession> {
	let mut owner = StartingService {
		service: Some(service),
		diagnostics: None,
		reaped: false,
		containment: ServiceContainment::default(),
	};
	let setup = (|| -> eyre::Result<BoundedDogmosClient> {
		let service = owner.service.as_mut().expect("startup owns child");
		owner.containment = ServiceContainment::attach(service)?;
		let stderr = service
			.stderr
			.take()
			.ok_or_else(|| eyre::eyre!("dogmosd stderr was not piped"))?;
		owner.diagnostics = Some(ServiceDiagnosticCapture::start(stderr));
		service
			.stdin
			.take()
			.ok_or_else(|| eyre::eyre!("dogmosd stdin was not piped"))?
			.write_all(&handshake.encode())?;
		let client = DogmosClient::connect(endpoint, handshake, timeout)?;
		Ok(BoundedDogmosClient::new(client)?)
	})();
	let client = match setup {
		Ok(client) => client,
		Err(error) => {
			let pid = owner.service.as_ref().expect("startup owns child").id();
			let cleanup = owner.cleanup();
			let diagnostic = owner
				.diagnostics
				.as_ref()
				.and_then(ServiceDiagnosticCapture::latest);
			return Err(error.wrap_err(format!(
				"dogmosd startup pid={pid} status={cleanup}; diagnostic={diagnostic:?}"
			)));
		}
	};
	Ok(ServiceSession {
		client,
		service: owner.service.take().expect("startup transfers child once"),
		diagnostics: owner
			.diagnostics
			.take()
			.expect("successful startup has diagnostics"),
		reaped: false,
		containment: std::mem::take(&mut owner.containment),
	})
}

#[cfg(windows)]
fn configure_service_command(command: &mut Command) {
	use std::os::windows::process::CommandExt;
	use windows_sys::Win32::System::Threading::CREATE_NO_WINDOW;

	command.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(unix)]
fn configure_service_command(command: &mut Command) {
	use std::os::unix::process::CommandExt;
	command.process_group(0);
}

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
		if let Some(scenario) = mode.strip_prefix("descendant-probe-") {
			run_descendant_probe(scenario);
			return;
		}
		if mode == "descendant-leaf" {
			thread::sleep(Duration::from_secs(5));
			return;
		}
		if mode == "descendant-startup" {
			// Match dogmosd's startup barrier: ownership/job attachment precedes stdin delivery.
			std::io::stdin()
				.read_exact(&mut [0_u8; HANDSHAKE_PAYLOAD_LEN])
				.unwrap();
			let _child = spawn_inherited_descendant();
			// The helper reads this pipe before starting the real startup path.
			println!("{}", _child.id());
			std::io::stdout().flush().unwrap();
			thread::sleep(Duration::from_secs(2));
			return;
		}
		if mode == "startup-exit" {
			eprintln!("fixture startup exit provenance");
			std::process::exit(19);
		}
		if mode == "stderr-flood" {
			let end = Instant::now() + Duration::from_secs(2);
			while Instant::now() < end {
				if std::io::stderr()
					.write_all(b"fixture continuous diagnostics\n")
					.is_err()
				{
					return;
				}
			}
			return;
		}
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
		if mode.starts_with("handshake-") {
			eprintln!("fixture handshake listener ready");
		}
		let mut stream = listener.accept().unwrap();
		let mut payload = [0_u8; HANDSHAKE_PAYLOAD_LEN];
		let (request, size) = read_frame_into(&mut stream, &mut payload).unwrap();
		let mut handshake = HandshakePayload::decode(&payload[..size]).unwrap();
		handshake.process_id = std::process::id();
		if mode == "handshake-stall" {
			thread::sleep(Duration::from_millis(350));
			return;
		}
		if mode == "handshake-truncated" {
			stream.write_all(&request.response().encode()[..8]).unwrap();
			thread::sleep(Duration::from_millis(350));
			return;
		}
		if mode == "handshake-mismatch" {
			handshake.auth_token[0] ^= 1;
		}
		if mode == "handshake-reject" {
			let mut response = request.response();
			response.flags |= dogmos_protocol::FLAG_ERROR;
			response.payload_len = 4;
			eprintln!("fixture handshake rejection provenance");
			write_frame(
				&mut stream,
				response,
				&dogmos_protocol::ServiceErrorCode::Busy.encode(),
			)
			.unwrap();
			return;
		}
		write_frame(&mut stream, request.response(), &handshake.encode()).unwrap();
		let descendant = if mode.starts_with("descendant") {
			let child = spawn_inherited_descendant();
			eprintln!("fixture descendant pid={}", child.id());
			Some(child)
		} else {
			None
		};

		let (mut request, size) = read_frame_into(&mut stream, &mut payload).unwrap();
		if mode == "late" {
			eprintln!("fixture late request provenance");
			thread::sleep(Duration::from_millis(350));
			let _ = write_frame(&mut stream, request.response(), &payload[..size]);
			return;
		}
		if mode == "server-error" {
			eprintln!("fixture failed request provenance");
			let mut response = request.response();
			response.flags |= dogmos_protocol::FLAG_ERROR;
			write_frame(
				&mut stream,
				response,
				&dogmos_protocol::ServiceErrorCode::Internal.encode(),
			)
			.unwrap();
			(request, _) = read_frame_into(&mut stream, &mut payload).unwrap();
		}
		if mode == "wrong-receipt" {
			let mut response = request.response();
			response.request_id += 1;
			write_frame(&mut stream, response, &payload[..size]).unwrap();
			thread::sleep(Duration::from_millis(350));
			return;
		}
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
		if mode == "descendant-clean" {
			// Simulate an exited service leaving a live inherited writer for its owner.
			if let Some(mut child) = descendant {
				child.0.take();
			}
			return;
		}
		if mode == "clean" || mode == "server-error" {
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

	fn fixture_command(mode: &str, endpoint: &str) -> Command {
		let mut command = Command::new(std::env::current_exe().unwrap());
		command
			.args([
				"--exact",
				"session::tests::fault_service_child",
				"--nocapture",
			])
			.env("DOGMOS_SESSION_FAULT_CHILD", mode)
			.env("DOGMOS_SESSION_FAULT_ENDPOINT", endpoint)
			.stdin(Stdio::piped())
			.stdout(Stdio::null())
			.stderr(Stdio::piped());
		configure_service_command(&mut command);
		command
	}

	fn spawn_fixture(mode: &str, endpoint: &str) -> FixtureChild {
		FixtureChild(Some(fixture_command(mode, endpoint).spawn().unwrap()))
	}

	fn spawn_inherited_descendant() -> FixtureChild {
		let mut command = Command::new(std::env::current_exe().unwrap());
		command
			.args([
				"--exact",
				"session::tests::fault_service_child",
				"--nocapture",
			])
			.env("DOGMOS_SESSION_FAULT_CHILD", "descendant-leaf")
			.stdin(Stdio::null())
			.stdout(Stdio::null())
			.stderr(Stdio::inherit());
		#[cfg(windows)]
		configure_service_command(&mut command);
		FixtureChild(Some(command.spawn().unwrap()))
	}

	#[cfg(windows)]
	struct ProcessProbe(std::os::windows::io::OwnedHandle);
	#[cfg(unix)]
	struct ProcessProbe(std::os::fd::OwnedFd);

	impl ProcessProbe {
		fn open(child: &Child) -> Self {
			#[cfg(windows)]
			{
				use std::os::windows::io::AsHandle;
				Self(child.as_handle().try_clone_to_owned().unwrap())
			}
			#[cfg(unix)]
			{
				use std::os::fd::FromRawFd;
				// SAFETY: pid identifies our still-owned child; flags zero requests a new pidfd.
				let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, child.id(), 0) };
				assert!(fd >= 0, "pidfd_open: {}", io::Error::last_os_error());
				// SAFETY: syscall returned a new live descriptor, transferred exactly once.
				Self(unsafe { std::os::fd::OwnedFd::from_raw_fd(fd as i32) })
			}
		}
		fn open_pid(pid: u32) -> Self {
			#[cfg(windows)]
			{
				use std::os::windows::io::FromRawHandle;
				use windows_sys::Win32::System::Threading::{
					OpenProcess, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE,
				};
				// SAFETY: child supplied this descendant PID while retaining its live child handle.
				let handle =
					unsafe { OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_TERMINATE, 0, pid) };
				assert!(
					!handle.is_null(),
					"OpenProcess: {}",
					io::Error::last_os_error()
				);
				// SAFETY: OpenProcess returned a newly owned live process handle.
				Self(unsafe { std::os::windows::io::OwnedHandle::from_raw_handle(handle) })
			}
			#[cfg(unix)]
			{
				use std::os::fd::FromRawFd;
				// SAFETY: child holds the descendant live; flags zero creates an owned pidfd.
				let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
				assert!(fd >= 0, "pidfd_open: {}", io::Error::last_os_error());
				// SAFETY: syscall returned a newly owned live descriptor.
				Self(unsafe { std::os::fd::OwnedFd::from_raw_fd(fd as i32) })
			}
		}

		fn exited(&self) -> bool {
			#[cfg(windows)]
			{
				use std::os::windows::io::AsRawHandle;
				// SAFETY: this duplicate handle owns the exact fixture process identity.
				unsafe {
					windows_sys::Win32::System::Threading::WaitForSingleObject(
						self.0.as_raw_handle(),
						0,
					) == windows_sys::Win32::Foundation::WAIT_OBJECT_0
				}
			}
			#[cfg(unix)]
			{
				use std::os::fd::AsRawFd;
				let mut fd = libc::pollfd {
					fd: self.0.as_raw_fd(),
					events: libc::POLLIN,
					revents: 0,
				};
				// SAFETY: one initialized descriptor points to the owned exact process pidfd.
				unsafe { libc::poll(&mut fd, 1, 0) > 0 }
			}
		}
		fn terminate(&self) {
			#[cfg(windows)]
			{
				use std::os::windows::io::AsRawHandle;
				// SAFETY: fallback cleanup targets only the owned fixture process handle.
				unsafe {
					windows_sys::Win32::System::Threading::TerminateProcess(
						self.0.as_raw_handle(),
						97,
					);
				}
			}
			#[cfg(unix)]
			{
				use std::os::fd::AsRawFd;
				// SAFETY: pidfd targets only the exact fixture; no PID name lookup/race.
				unsafe {
					libc::syscall(
						libc::SYS_pidfd_send_signal,
						self.0.as_raw_fd(),
						libc::SIGKILL,
						std::ptr::null::<libc::siginfo_t>(),
						0,
					);
				}
			}
		}
	}

	/// Only created inside the isolated Linux subreaper helper, or with a Windows process handle.
	struct DescendantCleanup {
		probe: ProcessProbe,
		#[cfg(unix)]
		pid: u32,
	}

	impl Drop for DescendantCleanup {
		fn drop(&mut self) {
			if !self.probe.exited() {
				self.probe.terminate();
			}
			#[cfg(unix)]
			{
				let mut status = 0;
				// SAFETY: the isolated helper is subreaper; the exact descendant is adopted after its parent is reaped.
				let result = unsafe { libc::waitpid(self.pid as i32, &mut status, 0) };
				assert_eq!(
					result,
					self.pid as i32,
					"descendant reap: {}",
					io::Error::last_os_error()
				);
			}
		}
	}

	fn run_descendant_probe(scenario: &str) {
		#[cfg(unix)]
		{
			assert_eq!(
				// SAFETY: isolated helper executable, never the main parallel test process.
				unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) },
				0
			);
		}
		let (descendant, elapsed, cleanup) = if scenario == "startup" {
			let endpoint = fixture_endpoint(44);
			let mut command = fixture_command("descendant-startup", &endpoint);
			command.stdout(Stdio::piped());
			let mut child = FixtureChild(Some(command.spawn().unwrap()));
			let stdout = child.stdout.take().unwrap();
			thread::scope(|scope| {
				let service = child.0.take().unwrap();
				let worker = scope.spawn(|| {
					let started = Instant::now();
					let result = start_spawned_service(
						service,
						&endpoint,
						fixture_handshake(),
						Duration::from_millis(100),
					);
					(started.elapsed(), result)
				});
				let mut line = String::new();
				use std::io::BufRead;
				let mut stdout = std::io::BufReader::new(stdout);
				// The Rust test harness also writes a preamble; find the explicit PID line.
				let pid = loop {
					line.clear();
					assert!(stdout.read_line(&mut line).unwrap() != 0);
					if let Ok(pid) = line.trim().parse::<u32>() {
						break pid;
					}
				};
				let descendant = DescendantCleanup {
					probe: ProcessProbe::open_pid(pid),
					#[cfg(unix)]
					pid,
				};
				let (elapsed, result) = worker.join().unwrap();
				(
					descendant,
					elapsed,
					format!("{:#}", result.err().expect("no listener must fail startup")),
				)
			})
		} else {
			let mut session = fixture_session(if scenario == "forced" {
				"descendant"
			} else {
				"descendant-clean"
			});
			let diagnostic = session
				.diagnostics
				.latest_after(0, Duration::from_secs(1))
				.unwrap();
			let pid = diagnostic
				.strip_prefix("fixture descendant pid=")
				.unwrap()
				.parse::<u32>()
				.unwrap();
			let descendant = DescendantCleanup {
				probe: ProcessProbe::open_pid(pid),
				#[cfg(unix)]
				pid,
			};
			assert!(!descendant.probe.exited());
			let started = Instant::now();
			let cleanup = if scenario == "forced" {
				session.terminate_service()
			} else if scenario == "health" {
				session
					.client
					.round_trip(OperationKind::Shutdown, &[], 0, Duration::from_secs(1))
					.unwrap();
				let deadline = Instant::now() + Duration::from_secs(1);
				while !session.reaped && Instant::now() < deadline {
					let _ = session.is_healthy().unwrap();
					thread::sleep(Duration::from_millis(1));
				}
				assert!(session.reaped);
				session.shutdown().unwrap();
				"health observed exit then repeated shutdown".into()
			} else {
				session.shutdown().unwrap();
				session.shutdown().unwrap();
				"clean then repeated shutdown".into()
			};
			let elapsed = started.elapsed();
			assert!(
				session.reaped
					&& session.client.is_worker_finished()
					&& session.diagnostics.worker.is_none()
			);
			// Check containment before dropping the session; drop must not hide missing shutdown cleanup.
			let deadline = Instant::now() + Duration::from_millis(100);
			while !descendant.probe.exited() && Instant::now() < deadline {
				thread::sleep(Duration::from_millis(1));
			}
			let contained = descendant.probe.exited();
			drop(session);
			assert!(
				contained,
				"{scenario} containment missing before session drop"
			);
			(descendant, elapsed, cleanup)
		};
		let deadline = Instant::now() + Duration::from_millis(100);
		while !descendant.probe.exited() && Instant::now() < deadline {
			thread::sleep(Duration::from_millis(1));
		}
		let contained = descendant.probe.exited();
		drop(descendant); // Kill/reap the exact leaf even when containment assertions fail.
		eprintln!(
			"descendant scenario={scenario} contained={contained} cleanup={elapsed:?}; {cleanup}"
		);
		assert!(
			contained,
			"{scenario} service cleanup did not contain descendant; elapsed={elapsed:?}"
		);
		assert!(elapsed < Duration::from_millis(750));
	}

	#[test]
	fn exact_child_cleanup_contains_descendant_with_inherited_stderr() {
		for scenario in ["forced", "clean", "health", "startup"] {
			let mut helper = spawn_fixture(&format!("descendant-probe-{scenario}"), "unused");
			let mut diagnostics = ServiceDiagnosticCapture::start(helper.stderr.take().unwrap());
			let deadline = Instant::now() + Duration::from_secs(3);
			let status = loop {
				if let Some(status) = helper.try_wait().unwrap() {
					break status;
				}
				if Instant::now() >= deadline {
					let _ = helper.kill();
					break helper.wait().unwrap();
				}
				thread::sleep(Duration::from_millis(5));
			};
			diagnostics.close();
			eprintln!(
				"descendant {scenario} helper status={status}; diagnostic={:?}",
				diagnostics.latest()
			);
			assert!(
				status.success(),
				"descendant {scenario} fixture failed: {:?}",
				diagnostics.latest()
			);
		}
	}

	#[test]
	fn partial_startup_releases_exact_child_on_missing_pipes() {
		for missing in ["stdin", "stderr"] {
			let mut child = spawn_fixture("stderr-open", "unused");
			let probe = ProcessProbe::open(&child);
			let pid = child.id();
			if missing == "stdin" {
				child.stdin.take();
			} else {
				child.stderr.take();
			}
			let started = Instant::now();
			let result = start_spawned_service(
				child.0.take().unwrap(),
				"unused",
				fixture_handshake(),
				Duration::from_millis(40),
			);
			let exited = probe.exited();
			if !exited {
				probe.terminate();
			}
			let error = result.err().expect("missing pipe must reject startup");
			eprintln!(
				"partial {missing} pid={pid} elapsed={:?} exact_child_exited={exited}; {error:#}",
				started.elapsed()
			);
			assert!(exited);
			assert!(format!("{error:#}").contains(&format!("dogmosd {missing} was not piped")));
			assert!(started.elapsed() < Duration::from_millis(750));
		}
	}

	#[test]
	fn failed_startup_preserves_provenance_and_releases_exact_child() {
		for mode in [
			"startup-exit",
			"handshake-reject",
			"handshake-mismatch",
			"handshake-stall",
			"handshake-truncated",
		] {
			let endpoint = fixture_endpoint(43);
			let mut child = spawn_fixture(mode, &endpoint);
			let probe = ProcessProbe::open(&child);
			let pid = child.id();
			let started = Instant::now();
			let result = start_spawned_service(
				child.0.take().unwrap(),
				&endpoint,
				fixture_handshake(),
				Duration::from_millis(100),
			);
			let elapsed = started.elapsed();
			let exited = probe.exited();
			if !exited {
				probe.terminate();
			}
			let error = result.err().expect("fault startup must fail");
			eprintln!("startup {mode} pid={pid} elapsed={elapsed:?} exact_child_exited={exited}; {error:#}");
			assert!(exited);
			assert!(elapsed < Duration::from_millis(750));
			assert!(error
				.chain()
				.any(|error| error.downcast_ref::<ClientError>().is_some()));
			let expected = match mode {
				"handshake-reject" => "ServerBusy",
				"handshake-mismatch" => "AuthenticationFailed",
				_ => "ConnectTimeout",
			};
			assert!(format!("{error:#}").contains(expected), "{error:#}");
		}
	}

	#[test]
	fn late_request_times_out_without_restart_and_releases_workers() {
		let mut session = fixture_session("late");
		let probe = ProcessProbe::open(&session.service);
		let pid = session.service.id();
		let started = Instant::now();
		let result: Result<(), ClientError> = session.request_with_response_timeout(
			OperationKind::Echo,
			b"late",
			4,
			Duration::from_millis(40),
			|_| Ok(()),
		);
		let elapsed = started.elapsed();
		eprintln!("late request pid={pid} elapsed={elapsed:?}; {result:?}");
		assert!(
			matches!(result, Err(ClientError::ServiceProcess { source, process_id, .. }) if matches!(*source, ClientError::RequestTimeout) && process_id == pid)
		);
		assert!(probe.exited());
		assert!(
			session.reaped
				&& session.client.is_worker_finished()
				&& session.diagnostics.worker.is_none()
		);
		assert!(matches!(
			session.client.echo(b"again", Duration::from_millis(40)),
			Err(ClientError::WorkerStopped)
		));
		assert_eq!(session.service.id(), pid);
		assert!(elapsed < Duration::from_millis(750));
		session.shutdown().unwrap();
	}

	#[test]
	fn server_rejection_keeps_error_provenance_and_allows_owned_shutdown() {
		let mut session = fixture_session("server-error");
		let pid = session.service.id();
		let result: Result<(), ClientError> = session.request_with_response_timeout(
			OperationKind::Echo,
			b"fail",
			4,
			Duration::from_secs(1),
			|_| Ok(()),
		);
		assert!(
			matches!(result, Err(ClientError::ServiceProcess { source, process_id, service_diagnostic: Some(diagnostic), .. }) if matches!(*source, ClientError::Server(dogmos_protocol::ServiceErrorCode::Internal)) && process_id == pid && diagnostic == "fixture failed request provenance")
		);
		assert!(session.is_healthy().unwrap());
		session.shutdown().unwrap();
		assert!(session.reaped && session.client.is_worker_finished());
	}

	#[test]
	fn malformed_receipt_stops_reuse_and_exact_child_is_reaped() {
		let mut session = fixture_session("wrong-receipt");
		let probe = ProcessProbe::open(&session.service);
		let result: Result<(), ClientError> = session.request_with_response_timeout(
			OperationKind::Echo,
			b"bad",
			3,
			Duration::from_secs(1),
			|_| Ok(()),
		);
		assert!(matches!(result, Err(ClientError::Protocol(_))));
		assert!(matches!(
			session.client.echo(b"again", Duration::from_millis(40)),
			Err(ClientError::WorkerStopped)
		));
		let _ = session.shutdown();
		assert!(probe.exited());
		assert!(
			session.reaped
				&& session.client.is_worker_finished()
				&& session.diagnostics.worker.is_none()
		);
	}

	#[test]
	fn diagnostic_close_bounds_a_continuously_written_stream() {
		let mut child = spawn_fixture("stderr-flood", "unused");
		let mut capture = ServiceDiagnosticCapture::start(child.stderr.take().unwrap());
		assert!(capture.latest_after(0, Duration::from_secs(1)).is_some());
		let started = Instant::now();
		capture.close();
		let elapsed = started.elapsed();
		let _ = child.kill();
		child.wait().unwrap();
		eprintln!("continuous writer diagnostic close: {elapsed:?}");
		assert!(elapsed < Duration::from_millis(500));
		assert!(capture.worker.is_none());
		assert!(capture.latest().unwrap().len() <= MAX_SERVICE_DIAGNOSTIC_BYTES);
	}

	fn assert_handshake_budget(mode: &str) {
		let endpoint = fixture_endpoint(42);
		let mut child = spawn_fixture(mode, &endpoint);
		let mut diagnostics = ServiceDiagnosticCapture::start(child.stderr.take().unwrap());
		assert_eq!(
			diagnostics
				.latest_after(0, Duration::from_secs(1))
				.as_deref(),
			Some("fixture handshake listener ready")
		);
		let started = Instant::now();
		let result =
			DogmosClient::connect(&endpoint, fixture_handshake(), Duration::from_millis(40));
		let elapsed = started.elapsed();
		let pid = child.id();
		let _ = child.kill();
		child.wait().unwrap();
		diagnostics.close();
		eprintln!(
			"{mode} pid={pid} connect elapsed={elapsed:?} result={:?}",
			result.as_ref().err()
		);
		assert!(
			matches!(result, Err(ClientError::ConnectTimeout)),
			"handshake deadline lost: {:?}",
			result.as_ref().err()
		);
		assert!(
			elapsed < Duration::from_millis(250),
			"handshake exceeded budget: {elapsed:?}"
		);
	}

	#[test]
	fn withheld_handshake_obeys_connection_budget() {
		assert_handshake_budget("handshake-stall");
	}

	#[test]
	fn truncated_handshake_obeys_connection_budget() {
		assert_handshake_budget("handshake-truncated");
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
		start_spawned_service(
			child.0.take().unwrap(),
			&endpoint,
			fixture_handshake(),
			Duration::from_secs(2),
		)
		.unwrap_or_else(|error| {
			panic!("fixture mode={mode} endpoint={endpoint} startup failed: {error:#}")
		})
	}

	#[test]
	fn request_cancellation_finishes_worker_while_service_is_still_alive() {
		let mut session = fixture_session("stall");
		assert!(matches!(
			session.client.echo(b"stall", Duration::from_millis(25)),
			Err(ClientError::RequestTimeout)
		));
		let closed = session.client.close(Duration::from_millis(500));
		let alive = session
			.containment
			.observe_exit(&mut session.service)
			.unwrap()
			.is_none();
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
