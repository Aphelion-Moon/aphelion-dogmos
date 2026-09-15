//! One ingress slot, one response slot, and a single I/O worker with no world access.

use dogmos_protocol::{read_frame_into, ProtocolHeader, MAX_CONTROL_PAYLOAD, PROTOCOL_HEADER_LEN};
use interprocess::{local_socket::Stream, TryClone};
use std::{
	io::{self, Write},
	sync::{
		atomic::{AtomicBool, Ordering},
		mpsc, Arc,
	},
	thread::{self, JoinHandle},
	time::{Duration, Instant},
};

type WorkerResult = Result<(), Box<dyn std::error::Error + Send + Sync>>;

#[derive(Default)]
pub(super) struct ResponseBuffer {
	bytes: Vec<u8>,
	len: usize,
}

impl ResponseBuffer {
	fn new(capacity: usize) -> Self {
		Self {
			bytes: vec![0; capacity],
			len: 0,
		}
	}
}

impl Write for ResponseBuffer {
	fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
		let end = self
			.len
			.checked_add(bytes.len())
			.filter(|end| *end <= self.bytes.len())
			.ok_or_else(|| io::Error::other("response exceeds fixed transport capacity"))?;
		self.bytes[self.len..end].copy_from_slice(bytes);
		self.len = end;
		Ok(bytes.len())
	}
	fn flush(&mut self) -> io::Result<()> {
		Ok(())
	}
}

pub(super) struct Incoming {
	pub(super) header: ProtocolHeader,
	pub(super) received_at: Instant,
	len: usize,
	payload: Vec<u8>,
	response: ResponseBuffer,
}

struct Outgoing {
	payload: Vec<u8>,
	response: ResponseBuffer,
	close: bool,
}

pub(super) struct Transport {
	requests: Option<mpsc::Receiver<Incoming>>,
	responses: Option<mpsc::SyncSender<Outgoing>>,
	response: ResponseBuffer,
	spare_request: Vec<u8>,
	outstanding: bool,
	worker: Option<JoinHandle<WorkerResult>>,
	stop: Arc<AtomicBool>,
	canceller: IoCanceller,
}

impl Transport {
	pub(super) fn new(stream: io::BufReader<Stream>) -> io::Result<Self> {
		let (request_tx, requests) = mpsc::sync_channel(1);
		let (responses, response_rx) = mpsc::sync_channel(1);
		let stop = Arc::new(AtomicBool::new(false));
		let cancel_stream = stream.get_ref().try_clone()?;
		let worker_stop = Arc::clone(&stop);
		let worker = thread::Builder::new()
			.name("dogmos-control-io".into())
			.spawn(move || io_worker(stream, request_tx, response_rx, worker_stop))?;
		let canceller = IoCanceller::new(cancel_stream);
		Ok(Self {
			requests: Some(requests),
			responses: Some(responses),
			response: ResponseBuffer::default(),
			spare_request: Vec::new(),
			outstanding: false,
			worker: Some(worker),
			stop,
			canceller,
		})
	}

	pub(super) fn receive(&mut self) -> io::Result<Incoming> {
		match self.requests.as_ref().ok_or_else(stopped)?.recv() {
			Ok(request) => Ok(request),
			Err(_) => Err(self.worker_error()),
		}
	}

	pub(super) fn try_receive(&mut self) -> io::Result<Option<Incoming>> {
		match self.requests.as_ref().ok_or_else(stopped)?.try_recv() {
			Ok(request) => Ok(Some(request)),
			Err(mpsc::TryRecvError::Empty) => Ok(None),
			Err(mpsc::TryRecvError::Disconnected) => Err(self.worker_error()),
		}
	}

	fn worker_error(&mut self) -> io::Error {
		match self.close(Duration::from_millis(100)) {
			Err(error) => io::Error::new(
				io::ErrorKind::BrokenPipe,
				format!("control I/O worker stopped: {error}"),
			),
			Ok(()) => stopped(),
		}
	}

	pub(super) fn install(
		&mut self,
		mut frame: Incoming,
		payload: &mut Vec<u8>,
	) -> io::Result<(ProtocolHeader, usize, Instant)> {
		if self.outstanding {
			return Err(io::Error::other("previous actor request has no response"));
		}
		std::mem::swap(payload, &mut frame.payload);
		self.spare_request = frame.payload;
		self.response = frame.response;
		self.response.len = 0;
		self.outstanding = true;
		Ok((frame.header, frame.len, frame.received_at))
	}

	pub(super) fn get_mut(&mut self) -> &mut ResponseBuffer {
		&mut self.response
	}

	pub(super) fn finish(&mut self, close: bool) -> io::Result<()> {
		if !self.outstanding {
			return Ok(());
		}
		if self.response.len < PROTOCOL_HEADER_LEN as usize {
			return Err(io::Error::other(
				"actor did not produce a complete response",
			));
		}
		let response = Outgoing {
			payload: std::mem::take(&mut self.spare_request),
			response: std::mem::take(&mut self.response),
			close,
		};
		self.responses
			.as_ref()
			.ok_or_else(stopped)?
			.try_send(response)
			.map_err(|_| io::Error::other("response slot unavailable"))?;
		self.outstanding = false;
		Ok(())
	}

	/// Wait for a graceful final reply. Failure is fatal to this authenticated session.
	pub(super) fn close(&mut self, timeout: Duration) -> WorkerResult {
		let deadline = Instant::now() + timeout;
		while self
			.worker
			.as_ref()
			.is_some_and(|worker| !worker.is_finished())
		{
			if Instant::now() >= deadline {
				return Err("control I/O shutdown deadline exceeded".into());
			}
			thread::sleep(Duration::from_millis(1));
		}
		self.join()
	}

	pub(super) fn abort(&mut self, timeout: Duration) -> WorkerResult {
		self.stop.store(true, Ordering::Release);
		self.requests.take();
		self.responses.take();
		let deadline = Instant::now() + timeout;
		while let Some(worker) = self.worker.as_ref().filter(|worker| !worker.is_finished()) {
			// Repeat cancellation to cover a worker entering I/O just after the stop check.
			self.canceller.cancel(worker)?;
			if Instant::now() >= deadline {
				return Err("control I/O cancellation deadline exceeded".into());
			}
			thread::sleep(Duration::from_millis(1));
		}
		// An aborted read/write is expected; joining still confirms worker ownership ended.
		if let Some(worker) = self.worker.take() {
			let _result = worker.join().map_err(|_| "control I/O worker panicked")?;
		}
		Ok(())
	}

	fn join(&mut self) -> WorkerResult {
		if let Some(worker) = self.worker.take() {
			worker.join().map_err(|_| "control I/O worker panicked")??;
		}
		Ok(())
	}
}

impl Drop for Transport {
	fn drop(&mut self) {
		if let Err(error) = self.abort(Duration::from_millis(100)) {
			eprintln!("DOGMOS CONTROL SHUTDOWN ERROR: {error}");
		}
	}
}

fn stopped() -> io::Error {
	io::Error::new(io::ErrorKind::BrokenPipe, "control I/O worker stopped")
}

fn io_worker(
	mut stream: io::BufReader<Stream>,
	requests: mpsc::SyncSender<Incoming>,
	responses: mpsc::Receiver<Outgoing>,
	stop: Arc<AtomicBool>,
) -> WorkerResult {
	let mut payload = vec![0; MAX_CONTROL_PAYLOAD as usize];
	let mut response =
		ResponseBuffer::new((MAX_CONTROL_PAYLOAD + u32::from(PROTOCOL_HEADER_LEN)) as usize);
	while !stop.load(Ordering::Acquire) {
		let (header, len) = read_frame_into(&mut stream, &mut payload)?;
		let frame = Incoming {
			header,
			len,
			received_at: Instant::now(),
			payload,
			response,
		};
		if requests.send(frame).is_err() {
			return Ok(());
		}
		let Ok(outgoing) = responses.recv() else {
			return Ok(());
		};
		if stop.load(Ordering::Acquire) {
			return Ok(());
		}
		stream
			.get_mut()
			.write_all(&outgoing.response.bytes[..outgoing.response.len])?;
		if outgoing.close {
			return Ok(());
		}
		payload = outgoing.payload;
		response = outgoing.response;
	}
	Ok(())
}

struct IoCanceller {
	stream: Stream,
}

impl IoCanceller {
	fn new(stream: Stream) -> Self {
		Self { stream }
	}

	#[cfg(windows)]
	fn cancel(&self, worker: &JoinHandle<WorkerResult>) -> io::Result<()> {
		use std::os::windows::io::{AsHandle, AsRawHandle};
		use windows_sys::Win32::{
			Foundation::ERROR_NOT_FOUND,
			System::IO::{CancelIoEx, CancelSynchronousIo},
		};
		let Stream::NamedPipe(pipe) = &self.stream;
		// SAFETY: both borrowed handles stay live for these calls and refer only to our worker.
		let overlapped = unsafe { CancelIoEx(pipe.as_handle().as_raw_handle(), std::ptr::null()) };
		let overlapped_error = (overlapped == 0).then(io::Error::last_os_error);
		let synchronous = unsafe { CancelSynchronousIo(worker.as_handle().as_raw_handle()) };
		let synchronous_error = (synchronous == 0).then(io::Error::last_os_error);
		// Capture each last-error value before another OS call can replace it. Attempt both
		// cancellation routes even when the first reports an unexpected error.
		match overlapped_error
			.into_iter()
			.chain(synchronous_error)
			.find(|error| error.raw_os_error() != Some(ERROR_NOT_FOUND as i32))
		{
			Some(error) => Err(error),
			None => Ok(()),
		}
	}

	#[cfg(unix)]
	fn cancel(&self, _worker: &JoinHandle<WorkerResult>) -> io::Result<()> {
		let Stream::UdSocket(stream) = &self.stream;
		stream.inner().shutdown(std::net::Shutdown::Both)
	}
}

#[cfg(test)]
#[path = "transport_tests.rs"]
mod tests;
