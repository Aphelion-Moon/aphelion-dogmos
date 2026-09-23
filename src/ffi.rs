use byondapi::prelude::ByondValue;
use byondapi::value::types::ValueType;
use eyre::Result;
use std::any::Any;
#[cfg(not(test))]
use std::io::Write;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

static FFI_PANIC_COUNT: AtomicU64 = AtomicU64::new(0);
// A panic before the first world opens callbacks still requires clean teardown.
static INITIALIZATION_PANICKED: AtomicBool = AtomicBool::new(false);

/// Adopts one owned API result without incrementing its reference count.
/// BYOND 516.1674+ returns persistent references, even on the main thread.
/// Never adopt borrowed binding arguments or a copied cached value.
pub(crate) struct OwnedByondValue(ByondValue);

impl OwnedByondValue {
	pub(crate) fn adopt(value: ByondValue) -> Self {
		Self(value)
	}

	pub(crate) fn into_inner(self) -> ByondValue {
		let value = self.0;
		std::mem::forget(self);
		value
	}
}

impl std::ops::Deref for OwnedByondValue {
	type Target = ByondValue;
	fn deref(&self) -> &Self::Target {
		&self.0
	}
}

impl Drop for OwnedByondValue {
	fn drop(&mut self) {
		// Null and numbers have no persistent reference. Inspect their public raw tag
		// so test stubs can release them without initializing the BYOND API.
		let tag = self.0 .0.type_;
		if tag != ValueType::Null as u8 && tag != ValueType::Number as u8 {
			self.0.decrement_ref();
		}
	}
}

pub(crate) fn panic_payload_message(payload: &(dyn Any + Send)) -> String {
	if let Some(message) = payload.downcast_ref::<String>() {
		message.clone()
	} else if let Some(message) = payload.downcast_ref::<&str>() {
		(*message).to_owned()
	} else {
		"<non-string panic payload>".to_owned()
	}
}

fn record_ffi_panic(binding: &'static str, payload: &(dyn Any + Send)) -> String {
	FFI_PANIC_COUNT.fetch_add(1, Ordering::Relaxed);
	let message = panic_payload_message(payload);
	#[cfg(test)]
	let _ = binding;
	#[cfg(not(test))]
	{
		let report = format!("[dogmos FFI guard] caught panic in {binding}: {message}\n");
		if let Ok(mut file) = std::fs::OpenOptions::new()
			.create(true)
			.append(true)
			.open("dogmos_panic.log")
		{
			let _ = file.write_all(report.as_bytes());
			let _ = file.flush();
		}
	}
	message
}

pub(crate) fn guard_with_arity<T>(
	binding: &'static str,
	request_values: u64,
	call: impl FnOnce() -> Result<T>,
) -> Result<T> {
	let telemetry = crate::DOGMOS_TELEMETRY.begin_sized(
		binding,
		request_values,
		std::mem::size_of::<ByondValue>() as u64,
		dogmos_perf::classify_binding(binding),
	);
	let diagnostic_or_shutdown = matches!(
		binding,
		"/proc/dogmos_shutdown"
			| "/proc/dogmos_in_process_identity"
			| "/proc/dogmos_in_process_capabilities"
			| "/proc/dogmos_in_process_metrics"
			| "/proc/dogmos_perf_snapshot"
			| "/proc/dogmos_perf_set_detailed"
			| "/proc/dogmos_ffi_panic_count"
			| "/proc/dogmos_callback_enqueue_failures"
	);
	let initializing = binding == "/proc/auxtools_atmos_init" && auxcallback::callbacks_closed();
	match catch_unwind(AssertUnwindSafe(|| {
		if binding == "/proc/auxtools_atmos_init" && INITIALIZATION_PANICKED.load(Ordering::Acquire)
		{
			return Err(eyre::eyre!(
				"Dogmos initialization panicked; perform clean shutdown before retrying"
			));
		}
		if matches!(
			binding,
			"/proc/auxtools_atmos_init" | "/proc/dogmos_shutdown"
		) {
			crate::reaction::ensure_registry_idle()?;
		}
		if binding == "/proc/auxtools_atmos_init" && !auxcallback::callbacks_closed() {
			return Err(eyre::eyre!(
				"Dogmos cannot initialize over a live world; perform clean shutdown first"
			));
		}
		if crate::DOGMOS_SHUTDOWN.load(Ordering::Acquire)
			&& !diagnostic_or_shutdown
			&& !initializing
		{
			return Err(eyre::eyre!("Dogmos is shutting down"));
		}
		if !diagnostic_or_shutdown
			&& !(binding == "/proc/auxtools_atmos_init" && auxcallback::callbacks_closed())
		{
			auxcallback::ensure_callbacks_healthy()?;
		}
		let value = call()?;
		if !diagnostic_or_shutdown {
			auxcallback::ensure_callbacks_healthy()?;
		}
		Ok(value)
	})) {
		Ok(Ok(value)) => {
			if binding == "/proc/dogmos_shutdown" {
				INITIALIZATION_PANICKED.store(false, Ordering::Release);
			}
			telemetry.finish(1);
			Ok(value)
		}
		Ok(Err(error)) => {
			if binding == "/proc/dogmos_shutdown" {
				crate::reset_shutdown_state(&crate::DOGMOS_SHUTDOWN);
				auxcallback::fault_simulation();
			}
			if initializing {
				auxcallback::fault_simulation();
			}
			telemetry.finish_error();
			Err(error)
		}
		Err(payload) => {
			auxcallback::fault_simulation();
			if binding == "/proc/dogmos_shutdown" {
				crate::reset_shutdown_state(&crate::DOGMOS_SHUTDOWN);
			}
			telemetry.finish_error();
			let message = record_ffi_panic(binding, payload.as_ref());
			Err(eyre::eyre!("Dogmos FFI panic in {binding}: {message}"))
		}
	}
}

pub(crate) fn guard_init(binding: &'static str, call: impl FnOnce()) {
	if let Err(payload) = catch_unwind(AssertUnwindSafe(call)) {
		INITIALIZATION_PANICKED.store(true, Ordering::Release);
		auxcallback::fault_simulation();
		record_ffi_panic(binding, payload.as_ref());
	}
}

pub(crate) fn ffi_panic_count() -> u64 {
	FFI_PANIC_COUNT.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
	use super::{ffi_panic_count, guard_init, guard_with_arity, panic_payload_message};
	use std::any::Any;
	use std::sync::atomic::Ordering;
	static FFI_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

	#[test]
	fn callback_failure_blocks_simulation_but_allows_shutdown_and_a_new_world() {
		let _guard = FFI_TEST_LOCK.lock().unwrap();
		auxcallback::begin_callbacks();
		assert!(auxcallback::queue_callback(Box::new(|| Ok(())), usize::MAX).is_err());
		let executed = std::cell::Cell::new(false);
		assert!(guard_with_arity("/proc/test_simulation", 0, || {
			executed.set(true);
			Ok(())
		})
		.is_err());
		assert!(!executed.get());
		assert!(guard_with_arity("/proc/auxtools_atmos_init", 0, || {
			auxcallback::begin_callbacks();
			Ok(())
		})
		.is_err());
		assert_eq!(
			guard_with_arity("/proc/dogmos_perf_snapshot", 0, || Ok(7)).unwrap(),
			7
		);
		assert_eq!(
			guard_with_arity("/proc/dogmos_in_process_metrics", 0, || Ok(8)).unwrap(),
			8
		);
		guard_with_arity("/proc/dogmos_shutdown", 0, || {
			auxcallback::clean_callbacks();
			Ok(())
		})
		.unwrap();
		let restarted = guard_with_arity("/proc/auxtools_atmos_init", 0, || {
			auxcallback::begin_callbacks();
			Ok(())
		});
		auxcallback::begin_callbacks();
		assert!(restarted.is_ok());
	}

	#[test]
	fn shutdown_rejects_reentrant_mutation_but_keeps_diagnostics_available() {
		let _guard = FFI_TEST_LOCK.lock().unwrap();
		auxcallback::begin_callbacks();
		crate::DOGMOS_SHUTDOWN.store(true, Ordering::Release);
		let executed = std::cell::Cell::new(false);
		let result = guard_with_arity("/proc/test_mutation", 0, || {
			executed.set(true);
			Ok(())
		});
		assert!(result.is_err());
		assert!(!executed.get());
		assert_eq!(
			guard_with_arity("/proc/dogmos_perf_snapshot", 0, || Ok(7)).unwrap(),
			7
		);
		crate::reset_shutdown_state(&crate::DOGMOS_SHUTDOWN);
	}

	#[test]
	fn formats_owned_string_panic_payloads() {
		let _guard = FFI_TEST_LOCK.lock().unwrap();
		let payload: Box<dyn Any + Send> = Box::new(String::from("owned panic"));
		assert_eq!(panic_payload_message(payload.as_ref()), "owned panic");
	}

	#[test]
	fn formats_borrowed_string_panic_payloads() {
		let _guard = FFI_TEST_LOCK.lock().unwrap();
		let payload: Box<dyn Any + Send> = Box::new("borrowed panic");
		assert_eq!(panic_payload_message(payload.as_ref()), "borrowed panic");
	}

	#[test]
	fn formats_non_string_panic_payloads() {
		let _guard = FFI_TEST_LOCK.lock().unwrap();
		let payload: Box<dyn Any + Send> = Box::new(17_u32);
		assert_eq!(
			panic_payload_message(payload.as_ref()),
			"<non-string panic payload>"
		);
	}

	#[test]
	fn guard_translates_panics_and_increments_telemetry() {
		let _guard = FFI_TEST_LOCK.lock().unwrap();
		auxcallback::begin_callbacks();
		let initial_count = ffi_panic_count();
		let result: eyre::Result<()> =
			guard_with_arity("/proc/test_guard", 0, || panic!("ffi panic"));
		let error = result.expect_err("guard must translate the panic into an error");
		assert!(error.to_string().contains("/proc/test_guard"));
		assert!(error.to_string().contains("ffi panic"));
		assert!(ffi_panic_count() > initial_count);
		assert!(guard_with_arity("/proc/test_mutation", 0, || Ok(())).is_err());
		assert!(guard_with_arity("/proc/dogmos_in_process_identity", 0, || Ok(())).is_ok());
		guard_with_arity("/proc/dogmos_shutdown", 0, || {
			auxcallback::clean_callbacks();
			Ok(())
		})
		.unwrap();
		guard_with_arity("/proc/auxtools_atmos_init", 0, || {
			auxcallback::begin_callbacks();
			Ok(())
		})
		.unwrap();
	}

	#[test]
	fn init_guard_contains_panics_and_increments_telemetry() {
		let _guard = FFI_TEST_LOCK.lock().unwrap();
		auxcallback::clean_callbacks();
		let initial_count = ffi_panic_count();
		guard_init("initialize_test", || panic!("init panic"));
		assert!(ffi_panic_count() > initial_count);
		assert!(auxcallback::ensure_callbacks_healthy().is_err());
		assert!(guard_with_arity("/proc/auxtools_atmos_init", 0, || {
			auxcallback::begin_callbacks();
			Ok(())
		})
		.is_err());
		guard_with_arity("/proc/dogmos_shutdown", 0, || {
			auxcallback::clean_callbacks();
			Ok(())
		})
		.unwrap();
		guard_with_arity("/proc/auxtools_atmos_init", 0, || {
			auxcallback::begin_callbacks();
			Ok(())
		})
		.unwrap();
	}

	#[test]
	fn guard_records_exact_binding_arity_and_result() {
		let _guard = FFI_TEST_LOCK.lock().unwrap();
		auxcallback::begin_callbacks();
		let binding = "/proc/test_perf_guard";
		let before = crate::DOGMOS_TELEMETRY
			.snapshot(0)
			.operations
			.into_iter()
			.find(|operation| operation.binding == binding)
			.map_or(0, |operation| operation.calls);
		let result: eyre::Result<u32> = guard_with_arity(binding, 3, || Ok(17));
		assert_eq!(result.unwrap(), 17);
		let operation = crate::DOGMOS_TELEMETRY
			.snapshot(0)
			.operations
			.into_iter()
			.find(|operation| operation.binding == binding)
			.unwrap();
		assert_eq!(operation.calls, before + 1);
		assert!(operation.request_values >= 3);
		assert!(operation.response_values >= 1);
	}
}
