open Eio.Std

(* Connect to socket at [path] (and then close it), to see if anyone's already listening there. *)
let is_listening path =
  let s = Unix.(socket PF_UNIX SOCK_STREAM 0) in
  Fun.protect ~finally:(fun () -> Unix.close s) @@ fun () ->
  match Unix.connect s (Unix.ADDR_UNIX path) with
  | () -> true
  | exception Unix.Unix_error(Unix.ECONNREFUSED, _, _) -> false
  | exception ex ->
    Log.warn (fun f -> f "Error testing socket %S: %a" path Fmt.exn ex);
    false

let on_error ex = Log.warn (fun f -> f "Error handling client: %a" Fmt.exn ex)

(* Start a daemon fiber listening for connections to [wayland_display]. *)
let listen_wayland ~sw ~net ~connect_host ~config wayland_display = 
  let socket_path = Wayland.Unix_transport.socket_path ~wayland_display () in
  let existing_socket = Sys.file_exists socket_path in
  if existing_socket && is_listening socket_path then (
    `Error (false, Fmt.str "A server is already listening on %S!" socket_path)
  ) else (
    if existing_socket then Unix.unlink socket_path;
    let listening_socket = Eio.Net.listen ~backlog:5 ~sw net (`Unix socket_path) in
    Log.info (fun f -> f "Listening on %S for Wayland clients" socket_path);
    Fiber.fork_daemon ~sw (fun () ->
        Eio.Net.run_server listening_socket ~on_error (fun conn addr ->
            Log.info (fun f -> f "New connection from %a" Eio.Net.Sockaddr.pp addr);
            try
              Switch.run ~name:"wayland-client" @@ fun sw ->
              let host = connect_host ~sw in
              Relay.run ~config host conn;
              (* The virtio transport doesn't support shutdown,
                 so force host listen fiber to be cancelled now. *)
              Switch.fail sw Exit
            with Exit -> ()
          )
      );
    `Ok ()
  )

(* Start a daemon fiber listening for connections to [x_display] and set $DISPLAY. *)
let listen_x11 ~sw ~net ~proc_mgr ~config ~connect_host x_display = 
  let xwayland_listening_socket =
    let path = Printf.sprintf "\x00/tmp/.X11-unix/X%d" x_display in
    let sock = Eio.Net.listen ~sw net (`Unix path) ~backlog:5 in
    Log.info (fun f -> f "Listening on %S for X clients" path);
    sock
  in
  Fiber.fork_daemon ~sw (fun () ->
      Xwayland.listen ~proc_mgr ~config ~connect_host ~display:x_display xwayland_listening_socket
    );
  Unix.putenv "DISPLAY" (Printf.sprintf ":%d" x_display)

let main ~env setup_tracing use_virtio_gpu wayland_display x_display config args =
  let proc_mgr = env#process_mgr in
  let net = env#net in
  Switch.run ~name:"main" @@ fun sw ->
  setup_tracing ~wayland_display;
  let connect_host ~sw =
    if use_virtio_gpu then (
      let dri_dir = Virtio_gpu.default_dri_dir env#fs in
      match Virtio_gpu.find_device ~sw dri_dir with
      | Ok virtio_gpu ->
        let transport = Virtio_gpu.wayland_transport virtio_gpu in
        Host.connect ~virtio_gpu ~sw transport
      | Error (`Msg m) ->
        Fmt.epr "No virtio-gpu device: %s@." m;
        exit 1
    ) else (
      let transport = Wayland.Unix_transport.connect ~sw ~net () in
      Host.connect ~sw transport
    )
  in
  (* Listen for incoming Wayland client connections: *)
  match listen_wayland ~sw ~net ~config ~connect_host wayland_display with
  | `Error _ as e -> e
  | `Ok () ->
    (* Listen for incoming X11 client connections, if configured: *)
    Option.iter (listen_x11 ~sw ~net ~proc_mgr ~config ~connect_host) x_display;
    (* Run the application (if any), or just wait (if not): *)
    match args with
    | [] -> Fiber.await_cancel ()
    | args ->
      let env =
        Unix.environment ()
        |> Array.to_list
        |> Unix_env.replace "WAYLAND_DISPLAY" wayland_display
        |> Array.of_list
      in
      let status = Eio.Process.spawn ~sw proc_mgr args ~env |> Eio.Process.await in
      Log.info (fun f -> f "Application process ended (%a)" Eio.Process.pp_status status);
      `Ok ()

open Cmdliner

let x_display =
  Arg.value @@
  Arg.(opt (some int)) None @@
  Arg.info
    ~doc:"Number of X display to listen on (e.g. 2 for DISPLAY=:2)"
    ["x-display"]

let wayland_display =
  Arg.value @@
  Arg.(opt string) "wayland-1" @@
  Arg.info
    ~doc:"Name or path of socket to listen on"
    ["wayland-display"]

let virtio_gpu =
  Arg.value @@
  Arg.flag @@
  Arg.info
    ~doc:"Use virtio-gpu to connect to compositor on host"
    ["virtio-gpu"]

let args =
  Arg.value @@
  Arg.(pos_all string) [] @@
  Arg.info
    ~doc:"Sub-command to execute"
    []

let () =
  Printexc.record_backtrace true;
  Eio_main.run @@ fun env ->
  let fs = fst env#fs in
  Switch.run ~name:"cli" @@ fun sw ->
  let virtwl_proxy =
    let info = Cmd.info "wayland-proxy-virtwl" in
    Cmd.v info Term.(ret (const (main ~env) $ Trace.cmdliner ~sw ~fs $ virtio_gpu $ wayland_display $ x_display $ Config.cmdliner $ args))
  in
  exit @@ Cmd.eval virtwl_proxy
