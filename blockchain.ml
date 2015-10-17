open Core.Std
open Async.Std

module Hardcoded = struct
  (* When answering an open Getheaders query, headers message should contain 2000 headers
     except for the last message that contains less headers. *)
  let max_headers = 2_000

  let get_more_headers_after = sec 600.

  let node_timeout = sec 60.
end

module Status = struct
  type t =
    | Not_connected
    | Syncing of Address.t
    | At_tip
end

module Header_check = struct
  type t =
    { addresses : Address.Hash_set.t
    ; hash_to_check : Hash.t
    ; hash_index : int
    ; start_time : Time.t
    }
end

type t =
  { mutable status : Status.t
  ; mutable headers : Header.t list
  ; mutable current_tip_hash : Hash.t
  ; mutable has_changed_since_last_write : bool
  ; mutable last_batch_processed : Time.t
  ; blockchain_file : string
  ; stop : unit Ivar.t
  ; network : Network.t
  ; mutable header_check : Header_check.t option
  ; mutable last_checked_index : int
  } with fields

let process_header t (header : Header.t) ~mark_as_changed =
  if Hash.(=) header.previous_block_header_hash t.current_tip_hash then begin
    t.headers <- header :: t.headers;
    t.current_tip_hash <- Header.hash header;
    if mark_as_changed then
      t.has_changed_since_last_write <- true;
  end else
    Core.Std.printf "Header hash mismatch!\n%!"

let write_blockchain_file t =
  let tmp_file = sprintf "%s.tmp" t.blockchain_file in
  let headers = List.rev t.headers in
  Writer.with_file tmp_file ~f:(fun writer ->
    Deferred.List.iter headers ~f:(fun header ->
      Writer.write_bin_prot writer Header.bin_writer_t header;
      Writer.flushed writer)
  )
  >>= fun () ->
  (* The rename operation is atomic, this avoids corrupting the file if the process dies
     while writing it. *)
  Unix.rename ~src:tmp_file ~dst:t.blockchain_file
  >>| fun () -> t.has_changed_since_last_write <- false

let genesis_hash =
  Hash.of_hex "0x000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"

let process_headers t ~node ~headers =
  let address = Node.address node in
  match t.status with
  | Syncing sync_address when Address.(=) sync_address address ->
    t.last_batch_processed <- Time.now ();
    let headers_len = List.length headers in
    let at_tip = List.length headers < Hardcoded.max_headers in
    let headers_len_pre = List.length t.headers in
    List.iter headers ~f:(fun (header : Header.t) ->
      process_header t header ~mark_as_changed:true);
    if at_tip then begin
      let headers_len_post = List.length t.headers in
      if headers_len_post = headers_len + headers_len_pre then
        t.status <- At_tip;
    end;
    Core.Std.printf "New blockchain length: %d\n%!" (List.length t.headers);
    if at_tip then ()
    else
      Node.send node (Message.getheaders ~from_hash:t.current_tip_hash)
  | Syncing _ | Not_connected | At_tip -> ()

let need_syncing t ~now:now_ =
  match t.status with
  | Not_connected -> true
  | Syncing _ -> false
  | At_tip ->
    Time.(add t.last_batch_processed Hardcoded.get_more_headers_after <= now_)

let sync_timeout t ~now:now_ =
  let timeout =
    match t.status with
    | Not_connected | At_tip -> false
    | Syncing _ ->
      Time.(add t.last_batch_processed Hardcoded.node_timeout <= now_)
  in
  if timeout then
    (* Maybe remove/blacklist the host ? *)
    t.status <- Not_connected

let start_syncing t node =
  t.status <- Syncing (Node.address node);
  Node.send node (Message.getheaders ~from_hash:t.current_tip_hash)

let close t =
  Ivar.fill_if_empty t.stop ()

let create ~blockchain_file ~network =
  let stop = Ivar.create () in
  let t =
    { status = Not_connected
    ; headers = []
    ; current_tip_hash = genesis_hash
    ; blockchain_file
    ; has_changed_since_last_write = false
    ; last_batch_processed = Time.epoch
    ; stop
    ; network
    ; header_check = None
    ; last_checked_index = -1
    }
  in
  Network.set_callbacks network ~process_headers:(process_headers t);
  Sys.file_exists blockchain_file
  >>= fun file_exists ->
  begin
    match file_exists with
    | `Yes ->
      Reader.with_file blockchain_file ~f:(fun reader ->
        let rec loop () =
          Reader.read_bin_prot reader Header.bin_reader_t
          >>= function
          | `Eof ->
            Deferred.unit
          | `Ok header ->
            process_header t header ~mark_as_changed:false;
            loop ()
        in
        loop ()
      )
    | `No | `Unknown -> Deferred.unit
  end
  >>| fun () ->
  Core.Std.printf "Read %d headers from %s.\n%!"
    (List.length t.headers) blockchain_file;
  let stop = Ivar.read stop in
  Clock.every' ~stop (sec 30.) (fun () ->
    if t.has_changed_since_last_write then write_blockchain_file t
    else Deferred.unit
  );
  Clock.every ~stop (sec 1.) (fun () ->
    let now = Time.now () in
    sync_timeout t ~now;
    let connected_nodes = Network.connected_nodes t.network in
    let connected_node_count = List.length connected_nodes in
    if 5 <= connected_node_count && need_syncing t ~now then begin
      List.nth_exn connected_nodes (Random.int connected_node_count)
      |> fun node -> start_syncing t node
    end
  );
  t
