open Lwt.Syntax
open Wayland

module H = struct
  include Wayland.Wayland_client
  include Wayland_protocols.Xdg_shell_client
  include Wayland_protocols.Xdg_output_unstable_v1_client
end

module C = struct
  include Wayland.Wayland_server
  include Wayland_protocols.Xdg_shell_server
  include Wayland_protocols.Xdg_output_unstable_v1_server
end

type t = {
  config : Config.t;
  virtwl : Wayland_virtwl.t;
  host_registry : Wayland.Registry.t;
}

type region_data = {
  host_region : [`V3] H.Wl_region.t;
}

type buffer = {
  host_buffer : [`V1] H.Wl_buffer.t;
  host_memory : Cstruct.t;
  client_memory : Cstruct.t;
}

type seat = {
  host_seat : [`V5] H.Wl_seat.t;
}

type surface = {
  host_surface : [`V3] H.Wl_surface.t;
  mutable host_memory : Cstruct.t;
  mutable client_memory : Cstruct.t;
}

type output = {
  host_output : ([`Wl_output], [`V2], [`Client]) Proxy.t;
}

type toplevel = {
  host_toplevel : ([`Xdg_toplevel], [`V1], [`Client]) Proxy.t;
}

type host_output = {
  client_output : ([`Wl_output], [`V1], [`Server]) Proxy.t;
}

type host_surface = {
  client_surface : ([`Wl_surface], [`V3], [`Server]) Proxy.t;
}

type xdg_surface = [`V1] H.Xdg_surface.t
type xdg_positioner = [`V1] H.Xdg_positioner.t

(* Note: the role here is our role: [`Server] data is attached to proxies to
 our clients (where we are the server), while [`Client] data is attached to host objects. *)
type ('a, 'role) user_data = 
  | Region      : region_data -> ([`Wl_region],    [`Server]) user_data
  | Surface     : surface     -> ([`Wl_surface],   [`Server]) user_data
  | Buffer      : buffer      -> ([`Wl_buffer],    [`Server]) user_data
  | Seat        : seat        -> ([`Wl_seat],      [`Server]) user_data
  | Output      : output      -> ([`Wl_output],    [`Server]) user_data
  | Toplevel    : toplevel    -> ([`Xdg_toplevel], [`Server]) user_data
  | Xdg_surface : xdg_surface -> ([`Xdg_surface],  [`Server]) user_data
  | Xdg_positioner : xdg_positioner -> ([`Xdg_positioner], [`Server]) user_data
  | Host_surface : host_surface -> ([`Wl_surface], [`Client]) user_data
  | Host_output  : host_output  -> ([`Wl_output],  [`Client]) user_data

type ('a, 'role) Wayland.S.user_data += Relay of ('a, 'role) user_data

let user_data (proxy : ('a, _, 'role) Proxy.t) : ('a, 'role) user_data =
  match Wayland.Proxy.user_data proxy with
  | Relay x -> x
  | S.No_data -> Fmt.failwith "No data attached to %a!" Proxy.pp proxy
  | _ -> Fmt.failwith "Unexpected data attached to %a!" Proxy.pp proxy

let client_output h =
  let Host_output { client_output } = user_data h in
  client_output

let client_surface surface =
  let Host_surface { client_surface } = user_data surface in
  client_surface

let host_surface surface =
  let Surface x = user_data surface in
  x.host_surface

let host_seat c =
  let Seat h = user_data c in
  h.host_seat

let host_output c =
  let Output h = user_data c in
  h.host_output

let host_region c =
  let Region h = user_data c in
  h.host_region

let host_toplevel c =
  let Toplevel h = user_data c in
  h.host_toplevel

let host_xdg_surface c =
  let Xdg_surface h = user_data c in
  h

let host_positioner c =
  let Xdg_positioner h = user_data c in
  h

let with_memory_fd t ~size f =
  let fd = Wayland_virtwl.alloc t.virtwl ~size in
  Fmt.pr "Got memory FD: %d@." (Obj.magic fd : int);
  Fun.protect
    (fun () -> f fd)
    ~finally:(fun () -> Unix.close fd)

(* When the client asks to destroy something, delay the ack until the host object is destroyed.
   This means the client sees events in the usual order, and means we can continue forwarding
   any events the host sends before hearing about the deletion. *)
let delete_with fn host client =
  Proxy.on_delete host (fun () -> Proxy.delete client);
  fn host

let make_region ~host_region:h r =
  let user_data = Relay (Region { host_region = h }) in
  Proxy.Handler.attach r @@ C.Wl_region.v3 ~user_data @@ object
    method on_add _ = H.Wl_region.add h
    method on_subtract _ = H.Wl_region.subtract h
    method on_destroy = delete_with H.Wl_region.destroy h
  end

let make_surface ~host_surface _t proxy =
  let data = { host_surface; host_memory = Cstruct.empty; client_memory = Cstruct.empty } in
  Proxy.Handler.attach proxy @@ C.Wl_surface.v3 ~user_data:(Relay (Surface data)) @@ object (_ : 'a C.Wl_surface.h3)
    method on_attach _ ~buffer ~x ~y =
      match buffer with
      | Some buffer ->
        let Buffer buffer = user_data buffer in
        data.host_memory <- buffer.host_memory;
        data.client_memory <- buffer.client_memory;
        H.Wl_surface.attach host_surface ~buffer:(Some buffer.host_buffer) ~x ~y
      | None ->
        data.host_memory <- Cstruct.empty;
        data.client_memory <- Cstruct.empty;
        H.Wl_surface.attach host_surface ~buffer:None ~x ~y
    method on_commit _ =
      (* todo: only copy the bit that changed *)
      Cstruct.blit data.client_memory 0 data.host_memory 0 (Cstruct.len data.client_memory);
      H.Wl_surface.commit host_surface
    method on_damage _ ~x ~y ~width ~height = H.Wl_surface.damage host_surface ~x ~y ~width ~height
    (*       method on_damage_buffer _ ~x ~y ~width ~height = H.Wl_surface.damage_buffer host_surface ~x ~y ~width ~height *)
    method on_destroy = delete_with H.Wl_surface.destroy host_surface
    method on_frame _ callback =
      let _ : _ Proxy.t = H.Wl_surface.frame host_surface @@ Wayland.callback @@ fun callback_data ->
        C.Wl_callback.done_ callback ~callback_data;
        Proxy.delete callback
      in
      Proxy.Handler.attach callback @@ C.Wl_callback.v1 ()
    method on_set_input_region _ ~region = H.Wl_surface.set_input_region host_surface ~region:(Option.map host_region region)
    method on_set_opaque_region _ ~region = H.Wl_surface.set_opaque_region host_surface ~region:(Option.map host_region region)
    method on_set_buffer_scale _ = H.Wl_surface.set_buffer_scale host_surface
    method on_set_buffer_transform _ ~transform:_ = failwith "Not implemented"
  end

let make_compositor t proxy =
  let host = Wayland.Registry.bind t.host_registry @@ H.Wl_compositor.v3 () in
  let _ : _ Proxy.t = Proxy.Service_handler.attach proxy @@ C.Wl_compositor.v3 @@ object
      method on_create_region _ region =
        let host_region = H.Wl_compositor.create_region host @@ H.Wl_region.v3 () in
        make_region ~host_region region

      method on_create_surface _ surface =
        let user_data = Relay (Host_surface { client_surface = surface }) in
        let host_surface = H.Wl_compositor.create_surface host @@ H.Wl_surface.v3 ~user_data @@ object (_ : _ H.Wl_surface.h3)
            method on_enter _ ~output = C.Wl_surface.enter surface ~output:(client_output output)
            method on_leave _ ~output = C.Wl_surface.leave surface ~output:(client_output output)
          end
        in
        make_surface ~host_surface t surface
    end
  in
  ()

let make_subsurface ~host_subsurface:h c =
  Proxy.Handler.attach c @@ C.Wl_subsurface.v1 @@ object (_ : 'a C.Wl_subsurface.h1)
    method on_destroy = delete_with H.Wl_subsurface.destroy h
    method on_place_above _ ~sibling = H.Wl_subsurface.place_above h ~sibling:(host_surface sibling)
    method on_place_below _ ~sibling = H.Wl_subsurface.place_below h ~sibling:(host_surface sibling)
    method on_set_desync _ = H.Wl_subsurface.set_desync h
    method on_set_position _ = H.Wl_subsurface.set_position h
    method on_set_sync _ = H.Wl_subsurface.set_sync h
  end

let make_subcompositor t proxy =
  let h = Wayland.Registry.bind t.host_registry @@ H.Wl_subcompositor.v1 () in
  let _ : _ Proxy.t = Proxy.Service_handler.attach proxy @@ C.Wl_subcompositor.v1 @@ object
      method on_destroy = delete_with H.Wl_subcompositor.destroy h

      method on_get_subsurface _ subsurface ~surface ~parent =
        let surface = host_surface surface in
        let parent = host_surface parent in
        let host_subsurface = H.Wl_subcompositor.get_subsurface h ~surface ~parent @@ H.Wl_subsurface.v1 () in
        make_subsurface ~host_subsurface subsurface
    end
  in
  ()

let make_buffer ~host_buffer ~host_memory ~client_memory proxy =
  let user_data = Relay (Buffer {host_buffer; host_memory; client_memory}) in
  Proxy.Handler.attach proxy @@ C.Wl_buffer.v1 ~user_data @@ object
    method on_destroy = delete_with H.Wl_buffer.destroy host_buffer
  end

type mapping = {
  host_pool : [`V1] H.Wl_shm_pool.t;
  client_memory_pool : Lwt_bytes.t;
  host_memory_pool : Lwt_bytes.t;
}

(* todo: this all needs to be more robust.
   Also, sealing? *)
let make_shm_pool t ~host_shm ~fd:client_fd ~size:orig_size proxy =
  let alloc ~size =
    let client_memory_pool = Unix.map_file client_fd Bigarray.Char Bigarray.c_layout true [| Int32.to_int size |] in
    let host_pool, host_memory_pool =
      with_memory_fd t ~size:(Int32.to_int size) (fun fd ->
          let host_pool = H.Wl_shm.create_pool host_shm ~fd ~size @@ H.Wl_shm_pool.v1 () in
          let host_memory = Wayland_virtwl.map_file fd Bigarray.Char ~n_elements:(Int32.to_int size) in
          host_pool, host_memory
        )
    in
    let host_memory_pool = Bigarray.array1_of_genarray host_memory_pool in
    let client_memory_pool = Bigarray.array1_of_genarray client_memory_pool in
    { host_pool; client_memory_pool; host_memory_pool }
  in
  let mapping = ref (alloc ~size:orig_size) in
  Proxy.Handler.attach proxy @@ C.Wl_shm_pool.v1 @@ object
    method on_create_buffer _ buffer ~offset ~width ~height ~stride ~format =
      let len = Int32.to_int height * Int32.to_int stride in
      let host_memory = Cstruct.of_bigarray (!mapping).host_memory_pool ~off:(Int32.to_int offset) ~len in
      let client_memory = Cstruct.of_bigarray (!mapping).client_memory_pool ~off:(Int32.to_int offset) ~len in
      let host_buffer =
        H.Wl_shm_pool.create_buffer (!mapping).host_pool ~offset ~width ~height ~stride ~format
        @@ H.Wl_buffer.v1 @@ object
          method on_release _ = C.Wl_buffer.release buffer
        end 
      in
      make_buffer ~host_buffer ~host_memory ~client_memory buffer

    method on_destroy t =
      Unix.close client_fd;
      delete_with H.Wl_shm_pool.destroy (!mapping).host_pool t

    method on_resize _ ~size =
      H.Wl_shm_pool.destroy (!mapping).host_pool;
      mapping := alloc ~size
  end

let make_output t c =
  let c = Proxy.cast_version c in
  let h =
    let user_data = Relay (Host_output { client_output = c }) in
    Wayland.Registry.bind t.host_registry @@ H.Wl_output.v2 ~user_data @@ object
      method on_done _ = C.Wl_output.done_ c
      method on_geometry _ = C.Wl_output.geometry c
      method on_mode _ = C.Wl_output.mode c
      method on_scale  _ = C.Wl_output.scale c
    end
  in
  let _ : _ Proxy.t =
    let user_data = Relay (Output { host_output = h }) in
    Proxy.Service_handler.attach c @@ C.Wl_output.v2 ~user_data () in
  ()

let make_seat t c =
  let c = Proxy.cast_version c in
  let cap_mask = C.Wl_seat.Capability.(Int32.logor keyboard pointer) in
  let host = Wayland.Registry.bind t.host_registry @@ H.Wl_seat.v5 @@ object
      method on_capabilities _ ~capabilities =
        C.Wl_seat.capabilities c ~capabilities:(Int32.logand capabilities cap_mask)
      method on_name _ = C.Wl_seat.name c
    end
  in
  let user_data = Relay (Seat { host_seat = host }) in
  let _ : _ Proxy.t = Proxy.Service_handler.attach c @@ C.Wl_seat.v5 ~user_data @@ object
      method on_get_keyboard _ keyboard =
        let h : _ Proxy.t = H.Wl_seat.get_keyboard host @@ H.Wl_keyboard.v5 @@ object
            method on_keymap    _ ~format ~fd ~size =
              C.Wl_keyboard.keymap keyboard ~format ~fd ~size;
              Unix.close fd
            method on_enter     _ ~serial ~surface = C.Wl_keyboard.enter keyboard ~serial ~surface:(client_surface surface)
            method on_leave     _ ~serial ~surface = C.Wl_keyboard.leave keyboard ~serial ~surface:(client_surface surface)
            method on_key       _ = C.Wl_keyboard.key keyboard
            method on_modifiers _ = C.Wl_keyboard.modifiers keyboard
            method on_repeat_info _ = C.Wl_keyboard.repeat_info keyboard
          end
        in
        Proxy.Handler.attach keyboard @@ C.Wl_keyboard.v5 @@ object
          method on_release = delete_with H.Wl_keyboard.release h
        end

      method on_get_pointer _ c =
        let h : _ Proxy.t = H.Wl_seat.get_pointer host @@ H.Wl_pointer.v5 @@ object
            method on_axis _ = C.Wl_pointer.axis c
            method on_axis_discrete _ = C.Wl_pointer.axis_discrete c
            method on_axis_source _ = C.Wl_pointer.axis_source c
            method on_axis_stop _ = C.Wl_pointer.axis_stop c
            method on_button _ = C.Wl_pointer.button c
            method on_enter _ ~serial ~surface = C.Wl_pointer.enter c ~serial ~surface:(client_surface surface)
            method on_leave _ ~serial ~surface = C.Wl_pointer.leave c ~serial ~surface:(client_surface surface)
            method on_motion _ = C.Wl_pointer.motion c
            method on_frame _ = C.Wl_pointer.frame c
          end
        in
        Proxy.Handler.attach c @@ C.Wl_pointer.v5 @@ object
          method on_set_cursor _ ~serial ~surface = H.Wl_pointer.set_cursor h ~serial ~surface:(Option.map host_surface surface)
          method on_release = delete_with H.Wl_pointer.release h
        end

      method on_get_touch _ = Fmt.failwith "TODO"
      method on_release = delete_with H.Wl_seat.release host
    end
  in
  ()

let make_shm t proxy =
  let proxy = Proxy.cast_version proxy in
  let host = Wayland.Registry.bind t.host_registry @@ H.Wl_shm.v1 @@ object
      method on_format _ = C.Wl_shm.format proxy
    end
  in
  let _ : _ Proxy.t = Proxy.Service_handler.attach proxy @@ C.Wl_shm.v1 @@ object
      method on_create_pool _ pool ~fd ~size =
        make_shm_pool t ~host_shm:host ~fd ~size pool
    end
  in
  ()

let make_popup ~host_popup:h proxy =
  Proxy.Handler.attach proxy @@ C.Xdg_popup.v1 @@ object (_ : 'a C.Xdg_popup.h1)
    method on_destroy = delete_with H.Xdg_popup.destroy h
    method on_grab _ ~seat ~serial = H.Xdg_popup.grab h ~seat:(host_seat seat) ~serial
  end

let make_toplevel config ~host_toplevel:h proxy =
  let user_data = Relay (Toplevel { host_toplevel = h }) in
  Proxy.Handler.attach proxy @@ C.Xdg_toplevel.v1 ~user_data @@ object (_ : 'a C.Xdg_toplevel.h1)
    method on_destroy = delete_with H.Xdg_toplevel.destroy h
    method on_move _ ~seat = H.Xdg_toplevel.move h ~seat:(host_seat seat)
    method on_resize _ ~seat = H.Xdg_toplevel.resize h ~seat:(host_seat seat)
    method on_set_app_id _ = H.Xdg_toplevel.set_app_id h
    method on_set_fullscreen _ ~output = H.Xdg_toplevel.set_fullscreen h ~output:(Option.map host_output output)
    method on_set_max_size _ = H.Xdg_toplevel.set_max_size h
    method on_set_maximized _ = H.Xdg_toplevel.set_maximized h
    method on_set_min_size _ = H.Xdg_toplevel.set_min_size h
    method on_set_minimized _ = H.Xdg_toplevel.set_minimized h
    method on_set_parent _ ~parent = H.Xdg_toplevel.set_parent h ~parent:(Option.map host_toplevel parent)
    method on_set_title _ ~title = H.Xdg_toplevel.set_title h ~title:(config.Config.tag ^ title)
    method on_show_window_menu _ ~seat = H.Xdg_toplevel.show_window_menu h ~seat:(host_seat seat)
    method on_unset_fullscreen _ = H.Xdg_toplevel.unset_fullscreen h
    method on_unset_maximized _ = H.Xdg_toplevel.unset_maximized h
  end

let make_xdg_surface config ~host_xdg_surface:h ~surface:_ proxy =
  let user_data = Relay (Xdg_surface h) in
  Proxy.Handler.attach proxy @@ C.Xdg_surface.v1 ~user_data @@ object (_ : _ C.Xdg_surface.h1)
    method on_ack_configure _ = H.Xdg_surface.ack_configure h
    method on_destroy = delete_with H.Xdg_surface.destroy h

    method on_get_popup _ popup ~parent ~positioner =
      let parent = Option.map host_xdg_surface parent in
      let positioner = host_positioner positioner in
      let host_popup = H.Xdg_surface.get_popup h ~parent ~positioner @@ H.Xdg_popup.v1 @@ object
          method on_popup_done _ = C.Xdg_popup.popup_done popup
          method on_configure _ = C.Xdg_popup.configure popup
        end
      in
      make_popup ~host_popup popup

    method on_get_toplevel _ toplevel =
      let host_toplevel = H.Xdg_surface.get_toplevel h @@ H.Xdg_toplevel.v1 @@ object
          method on_close _ = C.Xdg_toplevel.close toplevel
          method on_configure _ = C.Xdg_toplevel.configure toplevel
        end
      in
      make_toplevel config ~host_toplevel toplevel

    method on_set_window_geometry _ = H.Xdg_surface.set_window_geometry h
  end

let make_positioner ~host_positioner:h c =
  let user_data = Relay (Xdg_positioner h) in
  Proxy.Handler.attach c @@ C.Xdg_positioner.v1 ~user_data @@ object (_ : _ C.Xdg_positioner.h1)
    method on_destroy = delete_with H.Xdg_positioner.destroy h
    method on_set_anchor _ = H.Xdg_positioner.set_anchor h
    method on_set_anchor_rect _ = H.Xdg_positioner.set_anchor_rect h
    method on_set_constraint_adjustment _ = H.Xdg_positioner.set_constraint_adjustment h
    method on_set_gravity _ = H.Xdg_positioner.set_gravity h
    method on_set_offset _ = H.Xdg_positioner.set_offset h
    method on_set_size _ = H.Xdg_positioner.set_size h
  end

let make_xdg_wm_base t proxy =
  let proxy = Proxy.cast_version proxy in
  let host = Wayland.Registry.bind t.host_registry @@ H.Xdg_wm_base.v1 @@ object
      method on_ping _ = C.Xdg_wm_base.ping proxy
    end
  in
  let _ : _ Proxy.t = Proxy.Service_handler.attach proxy @@ C.Xdg_wm_base.v1 @@ object (_ : 'a C.Xdg_wm_base.h1)
      method on_create_positioner _ pos =
        let host_positioner = H.Xdg_wm_base.create_positioner host @@ H.Xdg_positioner.v1 () in
        make_positioner ~host_positioner pos

      method on_destroy = delete_with H.Xdg_wm_base.destroy host

      method on_get_xdg_surface _ xs ~surface =
        let Surface s = user_data surface in
        let host_xdg_surface = H.Xdg_wm_base.get_xdg_surface host ~surface:s.host_surface @@ H.Xdg_surface.v1 @@ object
            method on_configure _ ~serial = C.Xdg_surface.configure xs ~serial
          end
        in
        make_xdg_surface t.config ~host_xdg_surface ~surface xs
      method on_pong _ = H.Xdg_wm_base.pong host
    end
  in
  ()

let make_zxdg_output ~host_xdg_output:h c =
  Proxy.Handler.attach c @@ C.Zxdg_output_v1.v3 @@ object
    method on_destroy = delete_with H.Zxdg_output_v1.destroy h
  end

let make_zxdg_output_manager_v1 t proxy =
  let proxy = Proxy.cast_version proxy in
  let host = Wayland.Registry.bind t.host_registry @@ H.Zxdg_output_manager_v1.v3 () in
  let _ : _ Proxy.t = Proxy.Service_handler.attach proxy @@ C.Zxdg_output_manager_v1.v3 @@ object
      method on_destroy = delete_with H.Zxdg_output_manager_v1.destroy host

      method on_get_xdg_output _ c ~output =
        let output = host_output output in
        let h = H.Zxdg_output_manager_v1.get_xdg_output host ~output @@ H.Zxdg_output_v1.v3 @@ object
            method on_description _ = C.Zxdg_output_v1.description c
            method on_done _ = C.Zxdg_output_v1.done_ c
            method on_logical_position _ = C.Zxdg_output_v1.logical_position c
            method on_logical_size _ = C.Zxdg_output_v1.logical_size c
            method on_name _ = C.Zxdg_output_v1.name c
          end in
        make_zxdg_output ~host_xdg_output:h c
    end
  in
  ()

let make_data_device c =
  Proxy.Handler.attach c @@ C.Wl_data_device.v3 @@ object
    method on_release t = Proxy.delete t
    method on_set_selection _ ~source:_ ~serial:_ = ()
    method on_start_drag _ ~source:_ ~origin:_ ~icon:_ ~serial:_ = ()
  end

let make_data_device_manager t proxy =
  let proxy = Proxy.cast_version proxy in
  let _host = Wayland.Registry.bind t.host_registry @@ H.Wl_data_device_manager.v3 () in
  let _ : _ Proxy.t = Proxy.Service_handler.attach proxy @@ C.Wl_data_device_manager.v3 @@ object
      method on_create_data_source _ _source = failwith "TODO"
      method on_get_data_device _ data_device ~seat:_ =
        make_data_device data_device
    end
  in
  ()

type entry = Entry : int * (module Metadata.S) -> entry

let entry ~max_version m = Entry (max_version, m)

let pp_closed f = function
  | Ok () -> Fmt.string f "closed connection"
  | Error ex -> Fmt.pf f "connection failed: %a" Fmt.exn ex

let handle ~config client =
  let client_transport = Wayland.Unix_transport.of_socket client in
  let fd = Unix.(openfile "/dev/wl0" [O_RDWR; O_CLOEXEC] 0x600) in
  let virtwl = Wayland_virtwl.of_fd fd in
  let host_transport = Wayland_virtwl.new_context virtwl in
  let display, host_closed = Wayland.Display.connect host_transport in
  let* host_registry = Wayland.Registry.of_display display in
  let t = {
    virtwl;
    host_registry;
    config;
  } in
  let registry =
    let open Wayland_proto in
    let open Wayland_protocols.Xdg_shell_proto in
    let open Wayland_protocols.Xdg_output_unstable_v1_proto in
    Array.of_list [
      entry ~max_version:3 (module Wl_compositor);
      entry ~max_version:1 (module Wl_subcompositor);
      entry ~max_version:1 (module Wl_shm);
      entry ~max_version:1 (module Xdg_wm_base);
      entry ~max_version:5 (module Wl_seat);
      entry ~max_version:2 (module Wl_output);
      entry ~max_version:3 (module Wl_data_device_manager);
      entry ~max_version:3 (module Zxdg_output_manager_v1);
  ] in
  let s : Server.t =
    Server.connect client_transport (fun reg ->
        Proxy.Handler.attach reg @@ C.Wl_registry.v1 @@ object
          method on_bind : type a. _ -> name:int32 -> (a, [`Unknown], _) Proxy.t -> unit =
            fun _ ~name proxy ->
            let name = Int32.to_int name in
            if name < 0 || name >= Array.length registry then Fmt.failwith "Bad registry entry name %d" name;
            let Entry (max_version, (module M)) = registry.(name) in
            let requested_version = Int32.to_int (Proxy.version proxy) in
            if requested_version > max_version then
              Fmt.failwith "Client asked for %S v%d, but we only support up to %d" M.interface requested_version max_version;
            let client_interface = Proxy.interface proxy in
            if client_interface <> M.interface then
              Fmt.failwith "Entry %d has type %S, client expected %S!" name M.interface client_interface;
            let open Wayland_proto in
            let open Wayland_protocols.Xdg_shell_proto in
            let open Wayland_protocols.Xdg_output_unstable_v1_proto in
            match Proxy.ty proxy with
            | Wl_compositor.T -> make_compositor t proxy
            | Wl_subcompositor.T -> make_subcompositor t proxy
            | Wl_shm.T -> make_shm t proxy
            | Wl_seat.T -> make_seat t proxy
            | Wl_output.T -> make_output t proxy
            | Wl_data_device_manager.T -> make_data_device_manager t proxy
            | Xdg_wm_base.T -> make_xdg_wm_base t proxy
            | Zxdg_output_manager_v1.T -> make_zxdg_output_manager_v1 t proxy
            | _ -> Fmt.failwith "Invalid service name for %a" Proxy.pp proxy
        end;
        registry |> Array.iteri (fun i entry ->
            let Entry (max_version, (module M)) = entry in
            C.Wl_registry.global reg ~name:(Int32.of_int i) ~interface:M.interface ~version:(Int32.of_int max_version)
          );
      )
  in
  let is_active = ref true in
  let client_done =
    let* r = Server.closed s in
    if !is_active then (
      Log.info (fun f -> f "Client %a" pp_closed r);
      is_active := false
    );
    host_transport#close
  in
  let host_done =
    let* r = host_closed in
    if !is_active then (
      Log.info (fun f -> f "Host %a" pp_closed r);
      is_active := false
    );
    Lwt_unix.shutdown client Unix.SHUTDOWN_SEND;
    Lwt.return_unit
  in
  let* () = Lwt.choose [client_done; host_done] in
  Unix.close virtwl;
  Lwt_unix.close client
