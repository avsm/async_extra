open Core.Std
open Import

(* The reason for defining this module type explicitly is so that we can internally keep
   track of what is and isn't exposed. *)
module type Connection = sig
  module Implementations : sig
    type 'a t
  end

  type t

  (** Initiate an Rpc connection on the given reader/writer pair.  [server] should be the
      bag of implementations that the calling side implements; it defaults to
      [Implementations.null] (i.e., "I implement no RPCs").

      [connection_state] will be called once, before [create]'s result is determined, on
      the same connection that [create] returns.  Its output will be provided to the
      [implementations] when queries arrive.
  *)
  val create
    :  ?implementations   : 's Implementations.t
    -> connection_state   : (t -> 's)
    -> ?max_message_size  : int
    -> ?handshake_timeout : Time.Span.t
    -> Reader.t
    -> Writer.t
    -> (t, Exn.t) Result.t Deferred.t

  (** [close] starts closing the connection's reader and writer, and returns a deferred
      that becomes determined when their close completes.  It is ok to call [close]
      multiple times on the same [t]; calls subsequent to the initial call will have no
      effect, but will return the same deferred as the original call. *)
  val close          : t -> unit Deferred.t

  (** [close_finished] becomes determined after the close of the connection's reader and
      writer completes, i.e. the same deferred that [close] returns.  [close_finished]
      differs from [close] in that it does not have the side effect of initiating a close.
  *)
  val close_finished : t -> unit Deferred.t

  (** [is_closed t] returns [true] iff [close t] has been called. *)
  val is_closed      : t -> bool

  val bytes_to_write : t -> int

  (** [with_close] tries to create a [t] using the given reader and writer.  If a
      handshake error is the result, it calls [on_handshake_error], for which the default
      behavior is to raise an exception.  If no error results, [dispatch_queries] is
      called on [t].

      After [dispatch_queries] returns, if [server] is None, the [t] will be closed and
      the deferred returned by [dispatch_queries] wil be determined immediately.
      Otherwise, we'll wait until the other side closes the connection and then close [t]
      and determine the deferred returned by [dispatch_queries].

      When the deferred returned by [with_close] becomes determined, both [Reader.close]
      and [Writer.close] have finished.

      NOTE:  Because this connection is closed when the [Deferred.t] returned by
      [dispatch_queries] is determined, you should be careful when using this with
      [Pipe_rpc].  For example, simply returning the pipe when you get it will close the
      pipe immediately.  You should instead either use the pipe inside [dispatch_queries]
      and not determine its result until you are done with the pipe, or use a different
      function like [create].
  *)
  val with_close
    :  ?implementations   : 's Implementations.t
    -> ?max_message_size  : int
    -> ?handshake_timeout : Time.Span.t
    -> connection_state   : (t -> 's)
    -> Reader.t
    -> Writer.t
    -> dispatch_queries   : (t -> 'a Deferred.t)
    -> on_handshake_error : [ `Raise
                            | `Call of (Exn.t -> 'a Deferred.t)
                            ]
    -> 'a Deferred.t

  (** Runs [with_close] but dispatches no queries. The implementations are required
      because this function doesn't let you dispatch any queries (i.e., act as a client),
      it would be pointless to call it if you didn't want to act as a server.*)
  val server_with_close
    :  ?max_message_size  : int
    -> ?handshake_timeout : Time.Span.t
    -> Reader.t
    -> Writer.t
    -> implementations    : 's Implementations.t
    -> connection_state   : (t -> 's)
    -> on_handshake_error : [ `Raise
                            | `Ignore
                            | `Call of (Exn.t -> unit Deferred.t)
                            ]
    -> unit Deferred.t

  (** [serve implementations ~port ?on_handshake_error ()] starts a server with the given
      implementation on [port].  The optional auth function will be called on all incoming
      connections with the address info of the client and will disconnect the client
      immediately if it returns false.  This auth mechanism is generic and does nothing
      other than disconnect the client - any logging or record of the reasons is the
      responsibility of the auth function itself. *)
  val serve
    :  implementations          : 's Implementations.t
    -> initial_connection_state : ('address -> t -> 's)
    -> where_to_listen          : ('address, 'listening_on) Tcp.Where_to_listen.t
    -> ?max_connections         : int
    -> ?max_pending_connections : int
    -> ?buffer_age_limit        : Writer.buffer_age_limit
    -> ?max_message_size        : int
    -> ?handshake_timeout       : Time.Span.t
    -> ?auth                    : ('address -> bool)
    (** default is [`Ignore] *)
    -> ?on_handshake_error      : [ `Raise
                                  | `Ignore
                                  | `Call of (Exn.t -> unit)
                                  ]
    -> unit
    -> ('address, 'listening_on) Tcp.Server.t Deferred.t

  module Client_implementations : sig
    type nonrec 's t =
      { connection_state : t -> 's
      ; implementations  : 's Implementations.t
      }

    val null : unit -> unit t
  end

  (** [client ~host ~port ()] connects to the server at ([host],[port]) and returns the
      connection or an Error if a connection could not be made.  It is the responsibility
      of the caller to eventually call close.

      In [client] and [with_client], the [handshake_timeout] encompasses both the TCP
      connection timeout and the timeout for this module's own handshake.
  *)
  val client
    :  host                 : string
    -> port                 : int
    -> ?via_local_interface : Unix.Inet_addr.t  (** default is chosen by OS *)
    -> ?implementations     : _ Client_implementations.t
    -> ?max_message_size    : int
    -> ?buffer_age_limit    : Writer.buffer_age_limit
    -> ?handshake_timeout   : Time.Span.t
    -> unit
    -> (t, Exn.t) Result.t Deferred.t

  (** [with_client ~host ~port f] connects to the server at ([host],[port]) and runs f
      until an exception is thrown or until the returned Deferred is fulfilled.

      NOTE:  As with [with_close], you should be careful when using this with [Pipe_rpc].
      See [with_close] for more information.
  *)
  val with_client
    :  host                 : string
    -> port                 : int
    -> ?via_local_interface : Unix.Inet_addr.t  (** default is chosen by OS *)
    -> ?implementations     : _ Client_implementations.t
    -> ?max_message_size    : int
    -> ?handshake_timeout   : Time.Span.t
    -> (t -> 'a Deferred.t)
    -> ('a, Exn.t) Result.t Deferred.t
end