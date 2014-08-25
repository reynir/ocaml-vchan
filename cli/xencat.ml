open Cmdliner
open Sexplib.Std
open Vchan_lwt_unix

type clisrv = Client | Server

let (>>=) = Lwt.bind

module Xs = Xs_client_lwt.Client(Xs_transport_lwt_unix_client)

let listen =
  let doc = "Act as a server rather than a client." in
  Arg.(value & flag & info [ "l"; "listen"] ~doc)

let domid = Arg.(required & pos 0 (some int) None & info ~docv:"DOMID" ~doc:"Domain id of the remote endpoint." [])

let nodepath = Arg.(value & pos 1 (some string) None & info ~docv:"PATH" ~doc:"Xenstore path used to identify the connection (defaults to /local/domain/<domid>/data/vchan)." [])

let buf = String.create 5000

let (>>|=) m f = m >>= function
| `Ok x -> f x
| `Eof -> Lwt.fail (Failure "End of file")
| `Error (`Not_connected state) -> Lwt.fail (Failure (Printf.sprintf "Not in a connected state: %s" (Sexplib.Sexp.to_string (M.sexp_of_state state))))

let with_vchan_f vch =
  let (_: unit Lwt.t) =
    let rec read_forever vch =
      M.read vch >>|= fun buf ->
      Printf.printf "%s%!" (Cstruct.to_string buf);
      read_forever vch in
    read_forever vch in
  let (_: unit Lwt.t) =
    let rec stdin_to_endpoint vch =
      Lwt_io.read_line Lwt_io.stdin
      >>= fun line ->
      let line = line ^ "\n" in
      let buf = Cstruct.create (String.length line) in
      Cstruct.blit_from_string line 0 buf 0 (String.length line);
      M.write vch buf
      >>|= fun () ->
      stdin_to_endpoint vch in
    stdin_to_endpoint vch in
  let t, u = Lwt.task () in
  t

let with_vchan clisrv evtchn_h domid nodepath f =
  (match clisrv with
   | Client ->
     M.client ~evtchn_h ~domid ~xs_path:nodepath
   | Server ->
     M.server ~evtchn_h ~domid ~xs_path:nodepath
       ~read_size:5000 ~write_size:5000 ~persist:true)
  >>= fun vch ->
  f vch

let client domid nodepath =
  Client.connect ~domid ~path:nodepath
  >>= fun (ic, oc) ->
  let rec proxy a b =
    Lwt_io.read_char a
    >>= fun c ->
    Lwt_io.write_char b c
    >>= fun () ->
    proxy a b in
  let (a: unit Lwt.t) = proxy Lwt_io.stdin oc in
  let (b: unit Lwt.t) = proxy ic Lwt_io.stdout in
  Lwt.join [a; b]
  >>= fun () ->
  Client.close (ic, oc)

open Lwt

let node listen domid nodepath : unit = Lwt_main.run (
  ( match nodepath with
    | Some s -> return s
    | None ->
      ( if listen then begin
          Xs.make () >>= fun c ->
          Xs.(immediate c (fun h -> read h "domid")) >>= fun domid ->
          return (int_of_string domid)
        end else return domid ) >>= fun domid ->
      return ( Printf.sprintf "/local/domain/%d/data/vchan" domid ) )
  >>= fun nodepath ->
  (* Listen to incoming events. *)
  let evtchn_h = Eventchn.init () in
  if listen
  then with_vchan Server evtchn_h domid nodepath with_vchan_f
  else client domid nodepath
)

let cmd =
  let doc = "Establish vchan connections" in
  let man = [
    `S "DESCRIPTION";
    `P "Establish a connection to a remote Xen domain and transfer data over stdin/stdout, in a similar way to 'nc'";
  ] in
  Term.(pure node $ listen $ domid $ nodepath),
  Term.info "xencat" ~version:"0.1" ~doc ~man

let () =
  match Term.eval cmd with `Error _ -> exit 1 | _ -> exit 0
