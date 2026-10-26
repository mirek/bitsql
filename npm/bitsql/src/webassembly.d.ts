// The WebAssembly API members used here: TypeScript declares them only in
// lib.dom, which would also admit browser globals. Internal, not shipped.
declare namespace WebAssembly {
  class Module {
    constructor(bytes: Uint8Array)
  }
  class Instance {
    constructor(module: Module, imports: object)
    readonly exports: Record<string, unknown>
  }
  class Memory {
    readonly buffer: ArrayBuffer
  }
  function compile(bytes: Uint8Array): Promise<Module>
}
