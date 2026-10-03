///|
/// Parses a parameter declaration list such as "@a int, @b nvarchar(10) OUTPUT".
fn parse_param_decls(decls : String) -> Array[@ast.Param] raise {
  if decls.trim().is_empty() {
    return []
  }
  let stmt = @parse.parse_statement(
    "CREATE PROCEDURE __bitsql_params " + decls + " AS RETURN",
  )
  match stmt.kind {
    CreateProcedure(p) => p.params
    _ => []
  }
}

///|
/// One bound argument for a procedure or sp_executesql parameter.
priv struct Arg {
  value : @types.Value
  ty : @types.SqlType
  output : Bool
}

///|
/// Runs a body in a fresh frame with parameters, in RPC mode, and returns the
/// return status and the final values of OUTPUT parameters.
fn Session::run_with_params(
  self : Session,
  params : Array[@ast.Param],
  args : Map[String, Arg],
  positional : Array[Arg],
  body : () -> Bool raise,
) -> (Int, Array[(String, @types.SqlType, @types.Value, Bool)]) raise {
  let frame = Frame::new()
  let outs = []
  for i, p in params {
    let ty = @bind.resolve_type(p.type_, Declaration, @types.default_collation)
    let slot = frame.add_var(p.name, ty)
    let arg = match args.get(p.name.to_lower()) {
      Some(a) => Some(a)
      None => positional.get(i)
    }
    match arg {
      Some(a) => frame.values[slot] = @types.cast(a.value, a.ty, ty)
      None =>
        match p.default_ {
          Some(d) => {
            let b = @bind.bind_expr(@bind.Env::new(Map([])), d)
            let v = @exec.eval(self.ctx_with(frame), b)
            frame.values[slot] = @types.cast(v, b.ty, ty)
          }
          None => ()
        }
    }
    if p.output {
      outs.push((p.name, ty, slot, arg is Some({ output: true, .. })))
    }
  }
  self.frames.push(frame)
  self.rt.nest_level += 1
  let status = try {
    if body() {
      0
    } else {
      self.rt.error
    }
  } catch {
    Return(s) => s.unwrap_or(0)
    e => {
      self.frames.pop() |> ignore
      self.rt.nest_level -= 1
      raise e
    }
  }
  self.frames.pop() |> ignore
  self.rt.nest_level -= 1
  (status, outs.map(o => (o.0, o.1, frame.values[o.2], o.3)))
}

///|
fn Session::ctx_with(self : Session, frame : Frame) -> @exec.Ctx {
  {
    rt: self.rt,
    vars: frame.values,
    row: [],
    outer: [],
    source: (scope, id) => self.db_of(scope).rows(id),
    ext: (name, args) => self.catalog_fn(name, args),
  }
}

///|
fn Session::find_proc(self : Session, name : @ast.ObjectName) -> Proc raise {
  match self.server.procs.get(name.base().to_lower()) {
    Some(p) => p
    None =>
      raise @types.sql_error(
        2812,
        "Could not find stored procedure '\{name.parts.map(p => p.name).join(".")}'.",
      )
  }
}

///|
/// Runs an RPC request (sp_executesql, or a procedure by name).
pub fn Session::run_rpc(
  self : Session,
  call : @tds.RpcCall,
  now : Int64,
) -> Array[@reply.Item] {
  self.rt.now = now
  self.out.clear()
  self.rpc = true
  self.frames.clear()
  self.frames.push(Frame::new())
  let positional = []
  let named : Map[String, Arg] = Map([])
  let wire : Array[(@tds.RpcParam, Arg)] = call.params.map(p => {
    let ty = param_type(p.type_info)
    (p, Arg::{ value: param_value(ty, p.value), ty, output: p.by_ref, })
  })
  let result = try {
    match call.proc.canonical_name() {
      "sp_executesql" => {
        guard wire.get(0) is Some((_, { value: String(sql), .. })) else {
          raise @types.sql_error(
            214, "Procedure expects parameter '@statement' of type 'ntext/nchar/nvarchar'.",
          )
        }
        let decls = match wire.get(1) {
          Some((_, { value: String(d), .. })) => d
          _ => ""
        }
        let params = parse_param_decls(decls)
        for i in 2..<wire.length() {
          let (p, a) = wire[i]
          if p.name != "" {
            named[p.name.to_lower()] = a
          } else {
            positional.push(a)
          }
        }
        Some(
          self.run_with_params(params, named, positional, () => {
            self.run_text(sql)
          }),
        )
      }
      "sp_reset_connection" => Some((0, []))
      _ => {
        let name = match call.proc {
          Name(n) => n
          Id(_) => call.proc.canonical_name()
        }
        let obj = @parse.parse_statement("EXEC " + name)
        guard obj.kind is Exec({ target: ExecProc(on), .. }) else {
          raise @types.sql_error(
            2812,
            "Could not find stored procedure '\{name}'.",
          )
        }
        let proc = self.find_proc(on)
        for pair in wire {
          let (p, a) = pair
          if p.name != "" {
            named[p.name.to_lower()] = a
          } else {
            positional.push(a)
          }
        }
        Some(
          self.run_with_params(proc.def.params, named, positional, () => {
            self.exec_list(proc.def.body) catch {
              AbortBatch => return false
              e => raise e
            }
            true
          }),
        )
      }
    }
  } catch {
    @types.SqlError(..) as e => {
      self.message(e, 1)
      self.out.push(StatementDone(cmd=253, count=None, error=true))
      None
    }
    _ => None
  }
  match result {
    Some((status, outs)) => {
      self.out.push(ReturnStatus(status))
      for i, o in outs {
        let (name, ty, value, requested) = o
        if requested {
          self.out.push(
            ReturnValue(
              ordinal=i,
              name~,
              type_info=type_info(ty, true),
              value=wire_value(value),
            ),
          )
        }
      }
    }
    None => ()
  }
  self.frames.clear()
  let items = self.out.copy()
  self.out.clear()
  items
}

///|
/// EXEC proc statement inside a batch.
fn Session::exec_proc_stmt(self : Session, e : @ast.Exec) -> Unit raise {
  guard e.target is ExecProc(name) else {
    raise @types.not_supported("EXEC (@sql)")
  }
  let proc = self.find_proc(name)
  let named : Map[String, Arg] = Map([])
  let positional = []
  for a in e.args {
    let (v, ty) = self.eval(a.value)
    let arg : Arg = { value: v, ty, output: a.output, }
    match a.name {
      Some(n) => named[n.to_lower()] = arg
      None => positional.push(arg)
    }
  }
  let saved_rpc = self.rpc
  let (status, outs) = self.run_with_params(
    proc.def.params,
    named,
    positional,
    () => {
      self.exec_list(proc.def.body) catch {
        AbortBatch => return false
        e => raise e
      }
      true
    },
  )
  self.rpc = saved_rpc
  // write OUTPUT arguments back to the caller's variables
  for a in e.args {
    guard a.output && a.value.kind is Var(vname) else { continue }
    let pname = match a.name {
      Some(n) => n.to_lower()
      None => ""
    }
    for o in outs {
      if o.0.to_lower() == pname {
        match self.frame().vars.get(vname.to_lower()) {
          Some(info) =>
            self.frame().values[info.slot] = @types.cast(o.2, o.1, info.ty)
          None => ()
        }
      }
    }
  }
  match e.return_var {
    Some(rv) =>
      match self.frame().vars.get(rv.to_lower()) {
        Some(info) =>
          self.frame().values[info.slot] = @types.cast(
            Int(status),
            Int,
            info.ty,
          )
        None => ()
      }
    None => ()
  }
  self.out.push(ReturnStatus(status))
  self.done(224)
}
