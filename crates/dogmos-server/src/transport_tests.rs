use super::*;
use dogmos_protocol::{OperationKind, FLAG_RESPONSE};
use interprocess::local_socket::{prelude::*, GenericNamespaced, ListenerOptions};
use std::time::{SystemTime, UNIX_EPOCH};

fn pair() -> (Stream, Stream) {
	let id = SystemTime::now()
		.duration_since(UNIX_EPOCH)
		.unwrap()
		.as_nanos();
	let endpoint = format!("dogmos-actor-{}-{id}", std::process::id());
	let name = endpoint.to_ns_name::<GenericNamespaced>().unwrap();
	let listener = ListenerOptions::new()
		.name(name.clone())
		.create_sync()
		.unwrap();
	let client = Stream::connect(name).unwrap();
	(client, listener.accept().unwrap())
}

#[test]
fn transport_recycles_bounded_buffers_and_preserves_complete_frames() {
	let (mut peer, stream) = pair();
	let mut transport = Transport::new(io::BufReader::new(stream)).unwrap();
	let peer = thread::spawn(move || {
		for id in 1..=12 {
			let payload = vec![id as u8; 800];
			let header = ProtocolHeader::request(OperationKind::Echo, id, 7, 9, 800, 1000000);
			dogmos_protocol::write_frame(&mut peer, header, &payload).unwrap();
			let mut received = vec![0; 1024];
			let (reply, len) = read_frame_into(&mut peer, &mut received).unwrap();
			assert_eq!(reply.flags & FLAG_RESPONSE, FLAG_RESPONSE);
			assert_eq!(reply.request_id, id);
			assert_eq!(received[..len], payload);
		}
	});
	let mut payload = vec![0; MAX_CONTROL_PAYLOAD as usize];
	let mut request_addresses = std::collections::BTreeSet::new();
	let mut response_addresses = std::collections::BTreeSet::new();
	for id in 1..=12 {
		let frame = transport.receive().unwrap();
		assert_eq!(frame.header.request_id, id);
		assert!(frame.received_at <= Instant::now());
		let (request, len, _) = transport.install(frame, &mut payload).unwrap();
		request_addresses.insert(payload.as_ptr() as usize);
		response_addresses.insert(transport.get_mut().bytes.as_ptr() as usize);
		crate::write_response(transport.get_mut(), request, &payload[..len]).unwrap();
		transport.finish(id == 12).unwrap();
	}
	transport.close(Duration::from_secs(1)).unwrap();
	peer.join().unwrap();
	assert_eq!(request_addresses.len(), 2);
	assert_eq!(response_addresses.len(), 1);
}

#[test]
fn closing_transport_releases_an_idle_blocked_reader() {
	let (_peer, stream) = pair();
	let mut transport = Transport::new(io::BufReader::new(stream)).unwrap();
	assert!(transport.try_receive().unwrap().is_none());
	transport.abort(Duration::from_secs(1)).unwrap();
	assert!(transport.worker.is_none());
}

#[test]
fn closing_transport_releases_a_worker_waiting_for_actor_response() {
	let (mut peer, stream) = pair();
	let mut transport = Transport::new(io::BufReader::new(stream)).unwrap();
	let header = ProtocolHeader::request(OperationKind::Echo, 1, 7, 9, 0, 0);
	dogmos_protocol::write_frame(&mut peer, header, &[]).unwrap();
	let _received = transport.receive().unwrap();
	transport.abort(Duration::from_secs(1)).unwrap();
	assert!(transport.worker.is_none());
}

#[test]
fn response_buffer_rejects_overflow_without_growing() {
	let mut buffer = ResponseBuffer::new(8);
	buffer.write_all(&[1; 8]).unwrap();
	assert!(buffer.write_all(&[2]).is_err());
	assert_eq!(buffer.bytes, [1; 8]);
}

#[test]
fn closing_transport_releases_a_blocked_bulk_reply() {
	use std::io::Read;
	for _ in 0..4 {
		let (mut peer, stream) = pair();
		let mut transport = Transport::new(io::BufReader::new(stream)).unwrap();
		let header = ProtocolHeader::request(OperationKind::Echo, 1, 7, 9, 0, 0);
		dogmos_protocol::write_frame(&mut peer, header, &[]).unwrap();
		let frame = transport.receive().unwrap();
		let mut payload = vec![0; MAX_CONTROL_PAYLOAD as usize];
		transport.install(frame, &mut payload).unwrap();
		crate::write_response(transport.get_mut(), header, &payload).unwrap();
		transport.finish(false).unwrap();
		// Reading the header proves the worker entered its bulk write. Keep the peer alive
		// without consuming the payload so cancellation must release the worker's I/O.
		peer.read_exact(&mut [0; PROTOCOL_HEADER_LEN as usize])
			.unwrap();
		transport.abort(Duration::from_secs(1)).unwrap();
		assert!(transport.worker.is_none());
	}
}

#[test]
fn truncated_frame_closes_ingress_and_joins_the_owned_worker() {
	let (mut peer, stream) = pair();
	let mut transport = Transport::new(io::BufReader::new(stream)).unwrap();
	peer.write_all(&[0; 3]).unwrap();
	drop(peer);
	assert!(transport.receive().is_err());
	transport.close(Duration::from_secs(1)).unwrap();
	assert!(transport.worker.is_none());
}
