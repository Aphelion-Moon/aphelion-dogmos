#![deny(clippy::undocumented_unsafe_blocks)]

use dogmos_protocol::{
	read_frame_into, write_frame, HandshakePayload, OperationKind, ProtocolError, ProtocolHeader,
	ServiceErrorCode, TransportError, FLAG_ERROR, HANDSHAKE_PAYLOAD_LEN, MAX_CONTROL_PAYLOAD,
};
use interprocess::local_socket::{prelude::*, ConnectOptions, GenericNamespaced, Stream};
use std::{
	fmt, io,
	sync::mpsc::{self, SyncSender},
	thread,
	time::{Duration, Instant},
};

#[derive(Debug)]
pub enum ClientError {
	Io(io::Error),
	Protocol(ProtocolError),
	Transport(TransportError),
	ServerBusy,
	Server(ServiceErrorCode),
	ServiceProcess {
		source: Box<ClientError>,
		process_id: u32,
		process_state: String,
		service_diagnostic: Option<String>,
	},
	ConnectTimeout,
	RequestTimeout,
	WorkerStopped,
	WorkerShutdownTimeout,
}

impl fmt::Display for ClientError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::ServiceProcess {
				source,
				process_id,
				process_state,
				service_diagnostic,
			} => {
				write!(
					formatter,
					"{source}; dogmosd pid={process_id} status={process_state}"
				)?;
				if let Some(diagnostic) = service_diagnostic {
					write!(formatter, "; diagnostic={diagnostic}")?;
				}
				Ok(())
			}
			_ => write!(formatter, "{self:?}"),
		}
	}
}

impl std::error::Error for ClientError {
	fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
		match self {
			Self::ServiceProcess { source, .. } => Some(source.as_ref()),
			_ => None,
		}
	}
}

impl ClientError {
	fn is_fatal_connection_error(&self) -> bool {
		matches!(self, Self::Io(_) | Self::Protocol(_) | Self::Transport(_))
	}
}

impl From<io::Error> for ClientError {
	fn from(error: io::Error) -> Self {
		Self::Io(error)
	}
}

impl From<ProtocolError> for ClientError {
	fn from(error: ProtocolError) -> Self {
		Self::Protocol(error)
	}
}

impl From<TransportError> for ClientError {
	fn from(error: TransportError) -> Self {
		Self::Transport(error)
	}
}

/// Read buffer for the response side of the connection.
///
/// `write_frame` emits a small frame as a single write, so the matching response almost always
/// arrives as one readable chunk. Reading it through a buffer turns the header read and the
/// payload read into one syscall instead of two, and - unlike a speculative oversized read -
/// any bytes that arrive early are retained rather than lost.
const RESPONSE_BUFFER_BYTES: usize = 16 * 1024;

pub struct DogmosClient {
	stream: io::BufReader<Stream>,
	local: HandshakePayload,
	peer: HandshakePayload,
	next_request_id: u64,
}

impl DogmosClient {
	/// Connect and validate the peer within one endpoint/handshake budget.
	///
	/// A timed-out handshake is cancelled and its owned worker joined before returning
	/// `ConnectTimeout`. OS connection, cancellation and joining may delay cleanup;
	/// no worker is detached and no replacement authoritative world is created.
	pub fn connect(
		endpoint: &str,
		local: HandshakePayload,
		timeout: Duration,
	) -> Result<Self, ClientError> {
		let name = endpoint.to_ns_name::<GenericNamespaced>()?;
		let deadline = Instant::now() + timeout;
		let stream = loop {
			match ConnectOptions::new().name(name.clone()).connect_sync() {
				Ok(stream) => break stream,
				Err(error) if Instant::now() < deadline => {
					if !matches!(
						error.kind(),
						io::ErrorKind::NotFound
							| io::ErrorKind::ConnectionRefused
							| io::ErrorKind::WouldBlock
					) {
						return Err(ClientError::Io(error));
					}
					thread::sleep(Duration::from_millis(5));
				}
				Err(_) => return Err(ClientError::ConnectTimeout),
			}
		};
		Self::handshake_with_deadline(stream, local, deadline)
	}

	fn handshake_with_deadline(
		stream: Stream,
		local: HandshakePayload,
		deadline: Instant,
	) -> Result<Self, ClientError> {
		let io_token = stream_io_handle_token(&stream)?;
		let (setup_sender, setup_receiver) = mpsc::sync_channel(1);
		let (start_sender, start_receiver) = mpsc::sync_channel(1);
		let (result_sender, result_receiver) = mpsc::sync_channel(1);
		let worker = thread::Builder::new()
			.name("dogmos-handshake".into())
			.spawn(move || {
				let canceller = IoCanceller::new(current_thread_token(), io_token);
				if setup_sender.send(canceller).is_err() || start_receiver.recv().is_err() {
					return;
				}
				let _ = result_sender.send(Self::exchange_handshake(stream, local));
			})?;
		let mut owner = HandshakeWorker {
			worker: Some(worker),
			start: Some(start_sender),
			canceller: None,
		};
		owner.canceller = Some(
			setup_receiver
				.recv_timeout(deadline.saturating_duration_since(Instant::now()))
				.map_err(connect_receive_error)??,
		);
		owner
			.start
			.take()
			.expect("handshake start owned once")
			.send(())
			.map_err(|_| ClientError::WorkerStopped)?;
		let result = result_receiver
			.recv_timeout(deadline.saturating_duration_since(Instant::now()))
			.map_err(connect_receive_error)?;
		// A successful handshake returns a live stream: join without cancelling it.
		owner.join()?;
		result
	}

	fn exchange_handshake(
		mut stream: Stream,
		local: HandshakePayload,
	) -> Result<Self, ClientError> {
		let request = ProtocolHeader::request(
			OperationKind::Handshake,
			1,
			local.world_generation,
			local.world_nonce,
			HANDSHAKE_PAYLOAD_LEN as u32,
			0,
		);
		write_frame(&mut stream, request, &local.encode())?;
		let mut stream = io::BufReader::with_capacity(RESPONSE_BUFFER_BYTES, stream);
		let mut handshake_buffer = [0_u8; HANDSHAKE_PAYLOAD_LEN];
		let (response, response_len) = read_frame_into(&mut stream, &mut handshake_buffer)?;
		if response.flags & FLAG_ERROR != 0 {
			let code = ServiceErrorCode::decode(&handshake_buffer[..response_len])?;
			return match code {
				ServiceErrorCode::Busy => Err(ClientError::ServerBusy),
				other => Err(ClientError::Server(other)),
			};
		}
		response.validate_response_to(&request)?;
		let peer = HandshakePayload::decode(&handshake_buffer[..response_len])?;
		peer.validate_peer(&local)?;

		Ok(Self {
			stream,
			local,
			peer,
			next_request_id: 2,
		})
	}

	pub const fn peer(&self) -> &HandshakePayload {
		&self.peer
	}

	pub fn echo(&mut self, payload: &[u8]) -> Result<Vec<u8>, ClientError> {
		let mut response = vec![0_u8; payload.len()];
		let response_len = self.round_trip_into(OperationKind::Echo, payload, &mut response)?;
		response.truncate(response_len);
		Ok(response)
	}

	pub fn round_trip_into(
		&mut self,
		operation: OperationKind,
		payload: &[u8],
		response_buffer: &mut [u8],
	) -> Result<usize, ClientError> {
		self.round_trip_into_with_deadline(operation, payload, response_buffer, 0)
	}

	pub fn round_trip_into_with_deadline(
		&mut self,
		operation: OperationKind,
		payload: &[u8],
		response_buffer: &mut [u8],
		deadline_ns: u64,
	) -> Result<usize, ClientError> {
		let payload_len = u32::try_from(payload.len()).map_err(|_| {
			ClientError::Protocol(ProtocolError::PayloadTooLarge {
				actual: u32::MAX,
				maximum: MAX_CONTROL_PAYLOAD,
			})
		})?;
		let request = ProtocolHeader::request(
			operation,
			self.take_request_id(),
			self.local.world_generation,
			self.local.world_nonce,
			payload_len,
			deadline_ns,
		);
		write_frame(self.stream.get_mut(), request, payload)?;
		let (response, response_len) = read_frame_into(&mut self.stream, response_buffer)?;
		if response.flags & FLAG_ERROR != 0 {
			let code = ServiceErrorCode::decode(&response_buffer[..response_len])?;
			return Err(ClientError::Server(code));
		}
		response.validate_response_to(&request)?;
		Ok(response_len)
	}

	pub fn shutdown(&mut self) -> Result<(), ClientError> {
		let request = ProtocolHeader::request(
			OperationKind::Shutdown,
			self.take_request_id(),
			self.local.world_generation,
			self.local.world_nonce,
			0,
			0,
		);
		write_frame(self.stream.get_mut(), request, &[])?;
		let mut response_buffer = [];
		let (response, response_len) = read_frame_into(&mut self.stream, &mut response_buffer)?;
		response.validate_response_to(&request)?;
		if response_len != 0 {
			return Err(ClientError::Protocol(ProtocolError::TrailingBytes {
				expected_frame_len: dogmos_protocol::PROTOCOL_HEADER_LEN as u32,
				actual_frame_len: dogmos_protocol::PROTOCOL_HEADER_LEN as u32 + response_len as u32,
			}));
		}
		Ok(())
	}

	pub fn allocate_diagnostic(&mut self, bytes: u64) -> Result<u64, ClientError> {
		let mut response = [0_u8; 8];
		let response_len = self.round_trip_into(
			OperationKind::AllocateDiagnostic,
			&bytes.to_le_bytes(),
			&mut response,
		)?;
		if response_len != response.len() {
			return Err(ClientError::Protocol(ProtocolError::TruncatedPayload {
				expected_frame_len: dogmos_protocol::PROTOCOL_HEADER_LEN as u32 + 8,
				actual_frame_len: dogmos_protocol::PROTOCOL_HEADER_LEN as u32 + response_len as u32,
			}));
		}
		Ok(u64::from_le_bytes(response))
	}

	fn take_request_id(&mut self) -> u64 {
		let request_id = self.next_request_id;
		self.next_request_id = self.next_request_id.wrapping_add(1);
		request_id
	}
}

fn connect_receive_error(error: mpsc::RecvTimeoutError) -> ClientError {
	match error {
		mpsc::RecvTimeoutError::Timeout => ClientError::ConnectTimeout,
		mpsc::RecvTimeoutError::Disconnected => ClientError::WorkerStopped,
	}
}

/// Owns the startup worker even if setup fails before handshake I/O begins.
struct HandshakeWorker {
	worker: Option<thread::JoinHandle<()>>,
	start: Option<SyncSender<()>>,
	canceller: Option<IoCanceller>,
}

impl HandshakeWorker {
	fn join(&mut self) -> Result<(), ClientError> {
		self.start.take();
		if let Some(worker) = self.worker.take() {
			worker.join().map_err(|_| ClientError::WorkerStopped)?;
		}
		Ok(())
	}
}

impl Drop for HandshakeWorker {
	fn drop(&mut self) {
		self.start.take();
		let deadline = Instant::now() + Duration::from_secs(1);
		while self
			.worker
			.as_ref()
			.is_some_and(|worker| !worker.is_finished())
			&& Instant::now() < deadline
		{
			if let Some(canceller) = &self.canceller {
				let _ = canceller.cancel();
			}
			thread::sleep(Duration::from_millis(1));
		}
		if self
			.worker
			.as_ref()
			.is_some_and(|worker| !worker.is_finished())
		{
			eprintln!("dogmosd handshake cleanup exceeded its deadline; waiting for owned worker");
		}
		let _ = self.join();
	}
}

struct IoWorkerRequest {
	operation: OperationKind,
	payload: Vec<u8>,
	payload_len: usize,
	response: Vec<u8>,
	response_capacity: usize,
	deadline_ns: u64,
	result: Option<Result<usize, ClientError>>,
}

pub struct BoundedDogmosClient {
	sender: Option<SyncSender<IoWorkerRequest>>,
	response: mpsc::Receiver<IoWorkerRequest>,
	request: Option<IoWorkerRequest>,
	worker: Option<thread::JoinHandle<()>>,
	peer: HandshakePayload,
	canceller: IoCanceller,
	buffer_capacity: usize,
}

impl BoundedDogmosClient {
	pub fn new(mut client: DogmosClient) -> Result<Self, ClientError> {
		let peer = *client.peer();
		let buffer_capacity = peer.capacities.max_control_payload as usize;
		let io_handle_token = stream_io_handle_token(client.stream.get_ref())?;
		let (sender, receiver) = mpsc::sync_channel::<IoWorkerRequest>(1);
		let (response_sender, response) = mpsc::sync_channel::<IoWorkerRequest>(1);
		let (thread_sender, thread_receiver) = mpsc::sync_channel(1);
		let worker = thread::spawn(move || {
			if thread_sender.send(current_thread_token()).is_err() {
				return;
			}
			while let Ok(mut request) = receiver.recv() {
				request.result = Some(client.round_trip_into_with_deadline(
					request.operation,
					&request.payload[..request.payload_len],
					&mut request.response[..request.response_capacity],
					request.deadline_ns,
				));
				if response_sender.send(request).is_err() {
					return;
				}
			}
		});
		let thread_token = match thread_receiver.recv() {
			Ok(token) => token,
			Err(_) => {
				drop(sender);
				let _ = worker.join();
				return Err(ClientError::WorkerStopped);
			}
		};
		let canceller = match IoCanceller::new(thread_token, io_handle_token) {
			Ok(canceller) => canceller,
			Err(error) => {
				// No request was admitted: dropping the sender releases the idle worker.
				drop(sender);
				let _ = worker.join();
				return Err(error);
			}
		};
		Ok(Self {
			sender: Some(sender),
			response,
			request: Some(IoWorkerRequest {
				operation: OperationKind::Handshake,
				payload: vec![0_u8; buffer_capacity],
				payload_len: 0,
				response: vec![0_u8; buffer_capacity],
				response_capacity: 0,
				deadline_ns: 0,
				result: None,
			}),
			worker: Some(worker),
			peer,
			canceller,
			buffer_capacity,
		})
	}

	pub const fn peer(&self) -> &HandshakePayload {
		&self.peer
	}

	pub fn echo(&mut self, payload: &[u8], timeout: Duration) -> Result<Vec<u8>, ClientError> {
		Ok(self
			.round_trip(OperationKind::Echo, payload, payload.len(), timeout)?
			.to_vec())
	}

	pub const fn retained_buffer_capacities(&self) -> (usize, usize) {
		(self.buffer_capacity, self.buffer_capacity)
	}

	pub fn round_trip(
		&mut self,
		operation: OperationKind,
		payload: &[u8],
		response_capacity: usize,
		timeout: Duration,
	) -> Result<&[u8], ClientError> {
		if payload.len() > self.buffer_capacity {
			return Err(ClientError::Protocol(ProtocolError::PayloadTooLarge {
				actual: u32::try_from(payload.len()).unwrap_or(u32::MAX),
				maximum: self.peer.capacities.max_control_payload,
			}));
		}
		if response_capacity > self.buffer_capacity {
			return Err(ClientError::Protocol(ProtocolError::PayloadTooLarge {
				actual: u32::try_from(response_capacity).unwrap_or(u32::MAX),
				maximum: self.peer.capacities.max_control_payload,
			}));
		}
		let Some(sender) = self.sender.as_ref() else {
			return Err(ClientError::WorkerStopped);
		};
		let Some(mut request) = self.request.take() else {
			return Err(ClientError::WorkerStopped);
		};
		request.operation = operation;
		request.payload[..payload.len()].copy_from_slice(payload);
		request.payload_len = payload.len();
		request.response_capacity = response_capacity;
		request.deadline_ns = u64::try_from(timeout.as_nanos()).unwrap_or(u64::MAX);
		request.result = None;
		if let Err(error) = sender.send(request) {
			self.request = Some(error.0);
			return Err(ClientError::WorkerStopped);
		}
		match self.response.recv_timeout(timeout) {
			Ok(mut request) => {
				let result = request
					.result
					.take()
					.unwrap_or(Err(ClientError::WorkerStopped));
				self.request = Some(request);
				match result {
					Ok(response_len) => {
						Ok(&self.request.as_ref().unwrap().response[..response_len])
					}
					Err(error) => {
						if error.is_fatal_connection_error() {
							self.sender.take();
							let _ = self.canceller.cancel();
						}
						Err(error)
					}
				}
			}
			Err(mpsc::RecvTimeoutError::Timeout) => {
				self.sender.take();
				let _ = self.canceller.cancel();
				Err(ClientError::RequestTimeout)
			}
			Err(mpsc::RecvTimeoutError::Disconnected) => {
				self.sender.take();
				Err(ClientError::WorkerStopped)
			}
		}
	}

	pub fn is_worker_finished(&self) -> bool {
		self.worker
			.as_ref()
			.is_none_or(thread::JoinHandle::is_finished)
	}

	pub fn close(&mut self, timeout: Duration) -> Result<(), ClientError> {
		self.sender.take();
		if !self.is_worker_finished() {
			let _ = self.canceller.cancel();
		}
		let deadline = Instant::now() + timeout;
		while !self.is_worker_finished() && Instant::now() < deadline {
			// Cancellation can race a Windows worker between receiving a request and
			// entering its next system call. Retry until the owned worker completes.
			let _ = self.canceller.cancel();
			thread::sleep(Duration::from_millis(1));
		}
		if !self.is_worker_finished() {
			return Err(ClientError::WorkerShutdownTimeout);
		}
		if let Some(worker) = self.worker.take() {
			worker.join().map_err(|_| ClientError::WorkerStopped)?;
		}
		Ok(())
	}
}

impl Drop for BoundedDogmosClient {
	fn drop(&mut self) {
		if let Err(error) = self.close(Duration::from_secs(1)) {
			// Retain ownership until completion instead of silently detaching a worker.
			// OS cancellation failure is exceptional and cannot offer an absolute deadline.
			eprintln!("dogmosd request worker cleanup exceeded its deadline ({error}); waiting for owned worker");
			if let Some(worker) = self.worker.take() {
				let _ = worker.join();
			}
		}
	}
}

#[cfg(windows)]
struct IoCanceller {
	thread: std::os::windows::io::OwnedHandle,
	pipe: std::os::windows::io::OwnedHandle,
}

#[cfg(windows)]
impl IoCanceller {
	fn new(thread_id: u32, pipe: std::os::windows::io::OwnedHandle) -> Result<Self, ClientError> {
		use std::os::windows::io::FromRawHandle;
		use windows_sys::Win32::System::Threading::{OpenThread, THREAD_TERMINATE};

		// SAFETY: the thread ID came from the live worker; a successful call returns an owned handle.
		let handle = unsafe { OpenThread(THREAD_TERMINATE, 0, thread_id) };
		if handle.is_null() {
			return Err(ClientError::Io(io::Error::last_os_error()));
		}
		Ok(Self {
			// SAFETY: OpenThread returned a new handle owned by this caller.
			thread: unsafe { std::os::windows::io::OwnedHandle::from_raw_handle(handle) },
			pipe,
		})
	}

	fn cancel(&self) -> io::Result<()> {
		use std::os::windows::io::AsRawHandle;
		use windows_sys::Win32::System::IO::{CancelIoEx, CancelSynchronousIo};

		// SAFETY: the pipe is still owned by the worker while its request is outstanding.
		if unsafe { CancelIoEx(self.pipe.as_raw_handle(), std::ptr::null()) } == 0 {
			let error = io::Error::last_os_error();
			if error.raw_os_error() != Some(windows_sys::Win32::Foundation::ERROR_NOT_FOUND as i32)
			{
				return Err(error);
			}
		}

		// SAFETY: the handle remains live and identifies only the dedicated I/O worker thread.
		if unsafe { CancelSynchronousIo(self.thread.as_raw_handle()) } == 0 {
			let error = io::Error::last_os_error();
			if error.raw_os_error() != Some(windows_sys::Win32::Foundation::ERROR_NOT_FOUND as i32)
			{
				return Err(error);
			}
		}
		Ok(())
	}
}

#[cfg(windows)]
fn current_thread_token() -> u32 {
	// SAFETY: GetCurrentThreadId has no preconditions.
	unsafe { windows_sys::Win32::System::Threading::GetCurrentThreadId() }
}

#[cfg(windows)]
fn stream_io_handle_token(
	stream: &Stream,
) -> Result<std::os::windows::io::OwnedHandle, ClientError> {
	use interprocess::TryClone;

	match stream.try_clone()? {
		Stream::NamedPipe(stream) => Ok(stream.into()),
	}
}

#[cfg(not(windows))]
struct IoCanceller(std::os::unix::net::UnixStream);

#[cfg(not(windows))]
struct IoHandleToken(std::os::unix::net::UnixStream);

#[cfg(not(windows))]
impl IoCanceller {
	fn new(_thread_id: u32, pipe: IoHandleToken) -> Result<Self, ClientError> {
		Ok(Self(pipe.0))
	}

	fn cancel(&self) -> io::Result<()> {
		self.0.shutdown(std::net::Shutdown::Both)
	}
}

#[cfg(not(windows))]
fn current_thread_token() -> u32 {
	0
}

#[cfg(not(windows))]
fn stream_io_handle_token(stream: &Stream) -> Result<IoHandleToken, ClientError> {
	match stream {
		Stream::UdSocket(stream) => Ok(IoHandleToken(stream.inner().try_clone()?)),
	}
}

#[cfg(test)]
mod tests {
	use super::ClientError;
	use dogmos_protocol::ServiceErrorCode;

	#[test]
	fn service_process_context_is_caller_legible() {
		let error = ClientError::ServiceProcess {
			source: Box::new(ClientError::Server(ServiceErrorCode::Internal)),
			process_id: 42,
			process_state: "running".into(),
			service_diagnostic: Some(
				"DOGMOS SERVICE ERROR: operation=SimulationStage detail=stage conflict".into(),
			),
		};

		assert_eq!(
			error.to_string(),
			"Server(Internal); dogmosd pid=42 status=running; diagnostic=DOGMOS SERVICE ERROR: operation=SimulationStage detail=stage conflict"
		);
	}
}
