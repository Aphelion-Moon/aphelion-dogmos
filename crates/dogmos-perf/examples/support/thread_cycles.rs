use std::io;

#[cfg(windows)]
pub(super) fn current() -> io::Result<u64> {
	#[link(name = "kernel32")]
	extern "system" {
		fn GetCurrentThread() -> *mut std::ffi::c_void;
		fn QueryThreadCycleTime(thread: *mut std::ffi::c_void, cycles: *mut u64) -> i32;
	}
	let mut cycles = 0;
	// SAFETY: the pseudo-handle identifies this thread and the output points to a live u64.
	if unsafe { QueryThreadCycleTime(GetCurrentThread(), &mut cycles) } == 0 {
		return Err(io::Error::last_os_error());
	}
	Ok(cycles)
}

#[cfg(not(windows))]
pub(super) fn current() -> io::Result<u64> {
	Err(io::Error::new(
		io::ErrorKind::Unsupported,
		"thread cycle diagnostics require Windows",
	))
}

pub(super) fn elapsed(before: u64, after: u64) -> io::Result<u64> {
	after
		.checked_sub(before)
		.ok_or_else(|| io::Error::other("thread cycle counter moved backwards"))
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn deltas_reject_a_backwards_counter() {
		assert_eq!(elapsed(42, 57).unwrap(), 15);
		assert_eq!(elapsed(42, 42).unwrap(), 0);
		assert!(elapsed(57, 42).is_err());
	}

	#[cfg(windows)]
	#[test]
	fn current_thread_work_consumes_cycles() {
		let before = current().unwrap();
		let mut value = 1_u64;
		for number in 1..100_000 {
			value = std::hint::black_box(value.wrapping_mul(number).wrapping_add(1));
		}
		std::hint::black_box(value);
		assert!(elapsed(before, current().unwrap()).unwrap() > 0);
	}

	#[cfg(not(windows))]
	#[test]
	fn unsupported_platform_is_not_reported_as_zero_work() {
		assert_eq!(current().unwrap_err().kind(), io::ErrorKind::Unsupported);
	}
}
