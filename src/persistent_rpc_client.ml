open Core.Std
open Import

module Event = struct

  type t =
    | Attempting_to_connect
    | Obtained_address      of Host_and_port.t
    | Failed_to_connect     of Error.t
    | Connected
    | Disconnected
  with sexp

  type event = t

  module Handler = struct
    type t =
      { server_name : string
      ; on_event    : event -> unit
      ; log         : Log.t option
      }
  end

  let log_level = function
    | Attempting_to_connect | Connected | Disconnected | Obtained_address _ -> `Info
    | Failed_to_connect _ -> `Error

  let handle t { Handler. server_name; log; on_event } =
    on_event t;
    Option.iter log ~f:(fun log ->
      Log.sexp log t sexp_of_t ~level:(log_level t)
        ~tags:[("persistent-connection-to", server_name)])

end

module type S = sig
  type t
  type conn

  val create
    :  server_name : string
    -> ?log        : Log.t
    -> ?on_event   : (Event.t -> unit)
    -> connect     : (Host_and_port.t -> conn Or_error.t Deferred.t)
    -> (unit -> Host_and_port.t Or_error.t Deferred.t)
    -> t

  val connected : t -> conn Deferred.t

  val current_connection : t -> conn option

  val close : t -> unit Deferred.t

  val close_finished : t -> unit Deferred.t
end

module type T = sig
  type t
  val rpc_connection : t -> Rpc.Connection.t
end

module Make (Conn : T) = struct

  type conn = Conn.t

  type t =
    { get_address    : unit -> Host_and_port.t Or_error.t Deferred.t
    ; connect        : Host_and_port.t -> Conn.t Or_error.t Deferred.t
    ; mutable conn   : [`Ok of Conn.t | `Close_started] Ivar.t
    ; event_handler  : Event.Handler.t
    ; close_started  : unit Ivar.t
    ; close_finished : unit Ivar.t
    }
  with fields

  let handle_event t event = Event.handle event t.event_handler

  (* How long to wait between connection attempts.  This value is randomized to avoid all
     clients hitting the server at the same time. *)
  let retry_delay () = Time.Span.randomize ~percent:0.3 (sec 10.)

  (* This function focuses in on the the error itself, discarding information about which
     monitor caught the error, if any.

     If we don't do this, we sometimes end up with noisy logs which report the same error
     again and again, differing only as to what monitor caught them. *)
  let same_error e1 e2 =
    let to_sexp e = Exn.sexp_of_t (Monitor.extract_exn (Error.to_exn e)) in
    Sexp.equal (to_sexp e1) (to_sexp e2)

  let try_connecting_until_successful t =
    (* We take care not to spam logs with the same message over and over by comparing
       each log message the the previous one of the same type. *)
    let previous_address = ref None in
    let previous_error   = ref None in
    let connect () =
      t.get_address ()
      >>= function
      | Error e -> return (Error e)
      | Ok addr ->
        let same_as_previous_address =
          match !previous_address with
          | None -> false
          | Some previous_address -> Host_and_port.equal addr previous_address
        in
        previous_address := Some addr;
        if not same_as_previous_address then handle_event t (Obtained_address addr);
        t.connect addr
    in
    let rec loop () =
      if Ivar.is_full t.close_started then
        return `Close_started
      else begin
        connect ()
        >>= function
        | Ok conn -> return (`Ok conn)
        | Error err ->
          let same_as_previous_error =
            match !previous_error with
            | None -> false
            | Some previous_err -> same_error err previous_err
          in
          previous_error := Some err;
          if not same_as_previous_error then handle_event t (Failed_to_connect err);
          after (retry_delay ())
          >>= fun () ->
          loop ()
      end
    in
    loop ()

  let create ~server_name ?log ?(on_event = ignore) ~connect get_address =
    let event_handler = { Event.Handler. server_name; log; on_event } in
    let t =
      { event_handler
      ; get_address
      ; connect
      ; conn           = Ivar.create ()
      ; close_started  = Ivar.create ()
      ; close_finished = Ivar.create ()
      }
    in
    (* this loop finishes once [close t] has been called, in which case it makes sure to
       leave [t.conn] filled with [`Close_started]. *)
    don't_wait_for @@ Deferred.repeat_until_finished () (fun () ->
      handle_event t Attempting_to_connect;
      let ready_to_retry_connecting = after (retry_delay ()) in
      try_connecting_until_successful t
      >>= fun maybe_conn ->
      Ivar.fill t.conn maybe_conn;
      match maybe_conn with
      | `Close_started -> return (`Finished ())
      | `Ok conn ->
        handle_event t Connected;
        Rpc.Connection.close_finished (Conn.rpc_connection conn)
        >>= fun () ->
        t.conn <- Ivar.create ();
        handle_event t Disconnected;
        (* waits until [retry_delay ()] time has passed since the time just before we last
           tried to connect rather than the time we noticed being disconnected, so that if
           a long-lived connection dies, we will attempt to reconnect immediately. *)
        Deferred.choose [
          Deferred.choice ready_to_retry_connecting (fun () -> `Repeat ());
          Deferred.choice (Ivar.read t.close_started) (fun () ->
            Ivar.fill t.conn `Close_started;
            `Finished ());
        ]
    );
    t

  let connected t =
    (* Take care not to return a connection that is known to be closed at the time
       [connected] was called.  This could happen in client code that behaves like
       {[
         Persistent_rpc_client.connected t
         >>= fun c1 ->
         ...
           Rpc.Connection.close_finished c1
         (* at this point we are in a race with the same call inside
            persistent_client.ml *)
         >>= fun () ->
         Persistent_rpc_client.connected t
         (* depending on how the race turns out, we don't want to get a closed connection
            here *)
         >>= fun c2 ->
         ...
       ]}
       This doesn't remove the race condition, but it makes it less likely to happen.
    *)
    let rec loop () =
      let d = Ivar.read t.conn in
      match Deferred.peek d with
      | None ->
        begin
          d >>= function
          | `Close_started -> Deferred.never ()
          | `Ok conn -> return conn
        end
      | Some `Close_started -> Deferred.never ()
      | Some (`Ok conn) ->
        let rpc_conn = Conn.rpc_connection conn in
        if Rpc.Connection.is_closed rpc_conn then
          (* give the reconnection loop a chance to overwrite the ivar *)
          Rpc.Connection.close_finished rpc_conn >>= loop
        else
          return conn
    in
    loop ()

  let current_connection t =
    match Deferred.peek (Ivar.read t.conn) with
    | None | Some `Close_started -> None
    | Some (`Ok conn) -> Some conn

  let close_finished t = Ivar.read t.close_finished

  let close t =
    if Ivar.is_full t.close_started then
      (* Another call to close is already in progress.  Wait for it to finish. *)
      close_finished t
    else begin
      Ivar.fill t.close_started ();
      Ivar.read t.conn
      >>= fun conn_opt ->
      begin
        match conn_opt with
        | `Close_started -> Deferred.unit
        | `Ok conn -> Rpc.Connection.close (Conn.rpc_connection conn)
      end
      >>| fun () ->
      Ivar.fill t.close_finished ()
    end
end

module Versioned = Make (struct
    type t = Versioned_rpc.Connection_with_menu.t
    let rpc_connection = Versioned_rpc.Connection_with_menu.connection
  end)

include Make (struct
    type t = Rpc.Connection.t
    let rpc_connection = Fn.id
  end)

(* convenience wrapper *)
let create ~server_name ?log ?on_event ?via_local_interface ?implementations
      ?max_message_size ?make_transport ?handshake_timeout ?heartbeat_config get_address =
  let connect host_and_port =
    let (host, port) = Host_and_port.tuple host_and_port in
    Rpc.Connection.client ~host ~port ?via_local_interface ?implementations
      ?max_message_size ?make_transport ?handshake_timeout ?heartbeat_config
      ~description:(Info.of_string ("persistent connection to " ^ server_name)) ()
    >>| Or_error.of_exn_result
  in
  create ~server_name ?log ?on_event ~connect get_address
