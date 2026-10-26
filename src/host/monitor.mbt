///|
extern "C" fn clock_ticks() -> Int64 = "bitsql_clock_ticks"

///|
extern "C" fn cpu_us() -> Int64 = "bitsql_cpu_us"

///|
extern "C" fn cpu_count() -> Int = "bitsql_cpu_count"

///|
extern "C" fn memory_kb() -> Int64 = "bitsql_memory_kb"

///|
extern "C" fn socket_count() -> Int = "bitsql_socket_count"

///|
extern "C" fn cores_per_socket() -> Int = "bitsql_cores_per_socket"

///|
extern "C" fn numa_count() -> Int = "bitsql_numa_count"

///|
extern "C" fn container_type() -> Int = "bitsql_container_type"

///|
extern "C" fn boot_ms() -> Int64 = "bitsql_boot_ms"
