use dogmos_identity::{sha256_file, sha256_reader};
use std::{fs, io::Cursor};

const ABC_SHA256: [u8; 32] = [
	0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
	0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
];

#[test]
fn hashes_a_known_stream_without_buffering_the_whole_input() {
	assert_eq!(sha256_reader(Cursor::new(b"abc")).unwrap(), ABC_SHA256);
}

#[test]
fn file_hash_matches_stream_hash() {
	let path = std::env::temp_dir().join(format!("dogmos-sha256-{}.tmp", std::process::id()));
	fs::write(&path, b"abc").unwrap();
	let result = sha256_file(&path);
	let _ = fs::remove_file(&path);
	assert_eq!(result.unwrap(), ABC_SHA256);
}

#[test]
fn hashes_an_empty_stream() {
	assert_eq!(
		sha256_reader(Cursor::new(b"")).unwrap(),
		[
			0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f,
			0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b,
			0x78, 0x52, 0xb8, 0x55,
		],
	);
}

#[test]
fn hashes_input_larger_than_the_stream_buffer() {
	use std::io::Read;

	// The standard million-'a' vector crosses both SHA-256 blocks and read buffers.
	let input = std::io::repeat(b'a').take(1_000_000);
	assert_eq!(
		sha256_reader(input).unwrap(),
		[
			0xcd, 0xc7, 0x6e, 0x5c, 0x99, 0x14, 0xfb, 0x92, 0x81, 0xa1, 0xc7, 0xe2, 0x84, 0xd7,
			0x3e, 0x67, 0xf1, 0x80, 0x9a, 0x48, 0xa4, 0x97, 0x20, 0x0e, 0x04, 0x6d, 0x39, 0xcc,
			0xc7, 0x11, 0x2c, 0xd0,
		],
	);
}

#[test]
fn short_reads_do_not_truncate_the_digest() {
	struct ShortReads(Cursor<&'static [u8]>);
	impl std::io::Read for ShortReads {
		fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
			let length = buffer.len().min(1);
			std::io::Read::read(&mut self.0, &mut buffer[..length])
		}
	}

	assert_eq!(
		sha256_reader(ShortReads(Cursor::new(b"abc"))).unwrap(),
		ABC_SHA256
	);
}

#[test]
fn read_failure_does_not_return_a_partial_digest() {
	use std::io::{self, Read};

	struct FailedRead;
	impl Read for FailedRead {
		fn read(&mut self, _buffer: &mut [u8]) -> io::Result<usize> {
			Err(io::Error::from(io::ErrorKind::PermissionDenied))
		}
	}

	let input = Cursor::new(b"abc").chain(FailedRead);
	assert_eq!(
		sha256_reader(input).unwrap_err().kind(),
		io::ErrorKind::PermissionDenied
	);
}
