open Helper
open Middleware
open Store
open Matrix_common
open Matrix_stos
open Common_routes

let placeholder _ = assert false

let sign t encoding =
  Signatures.encoding
    [t.server_name, ["ed25519:" ^ t.key_name, t.priv_key]]
    encoding

module Key = struct
  module V2 = struct
    (* Notes:
       - Handle old_verify_keys
       - Use a proper and appropriate validity time
    *)
    let direct_query t _request =
      let open Key.Direct_query in
      (* The key_id path parameter is deprecated, and therefore ignored.
         Instead, all the keys are returned if several of them have been
         defined *)
      match
        Base64.encode ~pad:false
          (Cstruct.to_string
          @@ Mirage_crypto_ec.Ed25519.pub_to_cstruct t.pub_key)
      with
      | Ok base64_key ->
        let response =
          Response.make ~server_name:t.server_name
            ~verify_keys:
              [
                ( "ed25519:" ^ t.key_name,
                  Response.Verify_key.make ~key:base64_key () );
              ]
            ~old_verify_keys:[]
            ~valid_until_ts:(time () + 3600)
            ()
          |> Json_encoding.construct (sign t Response.encoding)
          |> Ezjsonm.value_to_string in
        Dream.json response
      | Error (`Msg s) ->
        Dream.error (fun m -> m "Base64 key encode error: %s" s);
        Dream.json ~status:`Internal_Server_Error {|{"errcode": "M_UNKOWN"}|}

    (* Notes:
       - Only fetching the key of the server for now
       - Should query other keys as well
       - Use a proper and appropriate validity time
    *)
    let indirect_query t request =
      let open Key.Indirect_batch_query in
      let%lwt body = Dream.body request in
      let requested_keys =
        Json_encoding.destruct Request.encoding (Ezjsonm.value_from_string body)
        |> Request.get_server_keys in
      let server_keys =
        match List.assoc_opt t.server_name requested_keys with
        | None -> []
        | Some keys -> (
          match List.assoc_opt ("ed25519:" ^ t.key_name) keys with
          | None -> []
          | Some _query_criteria -> (
            match
              Base64.encode ~pad:false
                (Cstruct.to_string
                @@ Mirage_crypto_ec.Ed25519.pub_to_cstruct t.pub_key)
            with
            | Ok base64_key ->
              [
                Key.Server_key.make ~server_name:t.server_name
                  ~verify_keys:
                    [
                      ( "ed25519:" ^ t.key_name,
                        Key.Server_key.Verify_key.make ~key:base64_key () );
                    ]
                  ~old_verify_keys:[]
                  ~valid_until_ts:(time () + 3600)
                  ();
              ]
            | Error (`Msg _s) -> [])) in
      let response =
        Response.make ~server_keys ()
        |> Json_encoding.construct (sign t Response.encoding)
        |> Ezjsonm.value_to_string in
      Dream.json response
  end
end

module Public_rooms = struct
  (* Notes:
     - Filter & pagination are ignored for now
  *)
  let get _t _request =
    let open Public_rooms.Get_public_rooms in
    let%lwt tree = Store.tree store in
    (* retrieve the list of the rooms *)
    let%lwt rooms = Store.Tree.list tree @@ Store.Key.v ["rooms"] in
    (* filter out the public rooms*)
    let%lwt public_rooms =
      Lwt_list.map_p
        (fun (room_id, room_tree) ->
          (* retrieve the room's canonical_alias if any *)
          let%lwt canonical_alias =
            let%lwt event_id =
              Store.Tree.find room_tree
              @@ Store.Key.v ["state"; "m.room.join_rules"] in
            match event_id with
            | None -> Lwt.return_none
            | Some event_id -> (
              let%lwt json =
                Store.Tree.get tree @@ Store.Key.v ["events"; event_id] in
              let event =
                Json_encoding.destruct Events.State_event.encoding
                  (Ezjsonm.value_from_string json) in
              match Events.State_event.get_event_content event with
              | Canonical_alias canonical_alias ->
                Lwt.return
                  (Option.join
                  @@ Events.Event_content.Canonical_alias.get_alias
                       canonical_alias)
              | _ -> Lwt.return_none) in
          (* retrieve the room's name if any *)
          let%lwt name =
            let%lwt event_id =
              Store.Tree.find room_tree @@ Store.Key.v ["state"; "m.room.name"]
            in
            match event_id with
            | None -> Lwt.return_none
            | Some event_id -> (
              let%lwt json =
                Store.Tree.get tree @@ Store.Key.v ["events"; event_id] in
              let event =
                Json_encoding.destruct Events.State_event.encoding
                  (Ezjsonm.value_from_string json) in
              match Events.State_event.get_event_content event with
              | Name name ->
                Lwt.return_some (Events.Event_content.Name.get_name name)
              | _ -> Lwt.return_none) in
          (* retrieve the room's members number *)
          let%lwt num_joined_members =
            let%lwt members =
              Store.Tree.list room_tree
              @@ Store.Key.v ["state"; "m.room.member"] in
            let f n (_, member_tree) =
              let%lwt event_id = Store.Tree.get member_tree @@ Store.Key.v [] in
              let%lwt json =
                Store.Tree.get tree @@ Store.Key.v ["events"; event_id] in
              let event =
                Json_encoding.destruct Events.State_event.encoding
                  (Ezjsonm.value_from_string json) in
              match Events.State_event.get_event_content event with
              | Member member ->
                if
                  Events.Event_content.Member.get_membership member
                  = Events.Event_content.Membership.Join
                then Lwt.return (n + 1)
                else Lwt.return n
              | _ -> Lwt.return n in
            Lwt_list.fold_left_s f 0 members in
          (* retrieve the room's topic if any *)
          let%lwt topic =
            let%lwt event_id =
              Store.Tree.find room_tree @@ Store.Key.v ["state"; "m.room.topic"]
            in
            match event_id with
            | None -> Lwt.return_none
            | Some event_id -> (
              let%lwt json =
                Store.Tree.get tree @@ Store.Key.v ["events"; event_id] in
              let event =
                Json_encoding.destruct Events.State_event.encoding
                  (Ezjsonm.value_from_string json) in
              match Events.State_event.get_event_content event with
              | Topic topic ->
                Lwt.return_some (Events.Event_content.Topic.get_topic topic)
              | _ -> Lwt.return_none) in
          (* retrieve the room's topic if any *)
          let%lwt avatar_url =
            let%lwt event_id =
              Store.Tree.find room_tree
              @@ Store.Key.v ["state"; "m.room.avatar"] in
            match event_id with
            | None -> Lwt.return_none
            | Some event_id -> (
              let%lwt json =
                Store.Tree.get tree @@ Store.Key.v ["events"; event_id] in
              let event =
                Json_encoding.destruct Events.State_event.encoding
                  (Ezjsonm.value_from_string json) in
              match Events.State_event.get_event_content event with
              | Avatar avatar ->
                Lwt.return_some (Events.Event_content.Avatar.get_url avatar)
              | _ -> Lwt.return_none) in
          (* Notes:
             - aliases are ignored for now
             - as guests are totally ignored, world_readable guest_can_join are
               set to false
             - federate is not in the documentation, so set to false for now,
               needs investigation in order to know what it means *)
          let room =
            Response.Public_rooms_chunk.make ~aliases:[] ?canonical_alias ?name
              ~num_joined_members ~room_id ?topic ~world_readable:false
              ~guest_can_join:false ?avatar_url ~federate:false () in
          Lwt.return room)
        rooms in
    let response =
      Response.make ~chunk:public_rooms
        ~total_room_count_estimate:(List.length rooms) ()
      |> Json_encoding.construct Response.encoding
      |> Ezjsonm.value_to_string in
    Dream.json response
end

module Join = struct
  (* Notes:
     - Work on the room versions !
     - Maybe change make join so it uses a member state event ?
     - Verify if the user if in the asking room ?
  *)
  let make t request =
    let open Joining_rooms.Make_join in
    let versions = Dream.queries "ver" request in
    let user_id = Dream.param "user_id" request in
    let room_id = Dream.param "room_id" request in
    (* FIX-ME: Hardcoded room version to 6 *)
    let room_version = "6" in
    if List.exists (String.equal room_version) versions then
      (* fetch the auth events *)
      let%lwt state_tree =
        Store.get_tree store (Store.Key.v ["rooms"; room_id; "state"]) in
      let%lwt create_event =
        Store.Tree.get state_tree (Store.Key.v ["m.room.create"]) in
      let%lwt power_level =
        Store.Tree.get state_tree (Store.Key.v ["m.room.power_levels"]) in
      let%lwt join_rules =
        Store.Tree.get state_tree (Store.Key.v ["m.room.join_rules"]) in
      let event_content =
        Events.Event_content.Member
          (Events.Event_content.Member.make ~membership:Join ()) in
      let%lwt old_depth, prev_events = get_room_prev_events room_id in
      let depth = old_depth + 1 in
      let origin =
        match Dream.local logged_server request with
        | Some logged_server -> logged_server
        | None -> t.server_name in
      let event_template =
        Events.Pdu.make
          ~auth_events:["$" ^ create_event; "$" ^ power_level; "$" ^ join_rules]
          ~event_content ~depth ~origin ~origin_server_ts:(time ()) ~prev_events
          ~prev_state:[] ~room_id ~sender:user_id ~signatures:[]
          ~state_key:user_id
          ~event_type:(Events.Event_content.get_type event_content)
          () in
      let response =
        Response.make ~room_version ~event_template ()
        |> Json_encoding.construct Response.encoding
        |> Ezjsonm.value_to_string in
      Dream.json response
    else
      Dream.json ~status:`Bad_Request
        (Fmt.str
           {|{"errcode": "M_INCOMPATIBLE_ROOM_VERSION", "error": "Your homeserver does not support the features required to join this room", "room_version": %s}|}
           room_version)

  (* Notes:
     - check if the user comes from the server asking the request
     - verify if the user is already in the room
     - verify the event content !
     - verify previous state
     - see what has to be done for the authentication chain
     - do something for the error prone generation of pdu
     - verify the event signature
     - verify the given event id
  *)
  let send t request =
    let open Joining_rooms.Send_join.V2 in
    let _event_id = Dream.param "event_id" request in
    let room_id = Dream.param "room_id" request in
    let%lwt body = Dream.body request in
    let member_event =
      Json_encoding.destruct Request.encoding (Ezjsonm.value_from_string body)
    in
    let member_event = compute_hash_and_sign t member_event in
    let event_id = compute_event_reference_hash member_event in
    (* need error handling *)
    let state_key = Events.Pdu.get_state_key member_event |> Option.get in
    let json_event =
      Json_encoding.construct Events.Pdu.encoding member_event
      |> Ezjsonm.value_to_string in
    let%lwt tree = Store.tree store in
    let%lwt tree =
      Store.Tree.add tree
        (Store.Key.v ["rooms"; room_id; "state"; "m.room.member"; state_key])
        event_id in
    let%lwt tree =
      Store.Tree.add tree (Store.Key.v ["events"; event_id]) json_event in
    (* save the new previous event id*)
    let json =
      Json_encoding.(construct (list string) [event_id])
      |> Ezjsonm.value_to_string in
    let%lwt tree =
      Store.Tree.add tree (Store.Key.v ["rooms"; room_id; "head"]) json in
    (* saving update tree *)
    let%lwt return =
      Store.set_tree
        ~info:(Helper.info t ~message:"add joining member")
        store (Store.Key.v []) tree in
    match return with
    | Ok () ->
      (* fetch the state of the room *)
      let%lwt tree = Store.tree store in
      let%lwt state_tree =
        Store.Tree.get_tree tree (Store.Key.v ["rooms"; room_id; "state"]) in
      let%lwt state =
        Store.Tree.fold
          ~contents:(fun _ event_id events ->
            let open Events in
            let%lwt json =
              Store.Tree.get tree @@ Store.Key.v ["events"; event_id] in
            let event =
              Ezjsonm.from_string json |> Json_encoding.destruct Pdu.encoding
            in
            Lwt.return (event :: events))
          state_tree [] in
      let response =
        Response.make ~origin:t.server_name ~auth_chain:state ~state ()
        |> Json_encoding.construct Response.encoding
        |> Ezjsonm.value_to_string in
      Dream.json response
    | Error write_error ->
      Dream.error (fun m ->
          m "Write error: %a" (Irmin.Type.pp Store.write_error_t) write_error);
      Dream.json ~status:`Internal_Server_Error {|{"errcode": "M_UNKNOWN"}|}
end

module Retrieve = struct
  (* Notes:
     - Verify if the room asking for the event is entitled to do so
     - Needs a better error handling *)
  let get_event t request =
    let open Retrieve.Event in
    let event_id = Dream.param "event_id" request in
    let%lwt tree = Store.tree store in
    let event_id = Identifiers.Event_id.of_string_exn event_id in
    let%lwt json = Store.Tree.find tree @@ Store.Key.v ["events"; event_id] in
    match json with
    | None -> Dream.json ~status:`Forbidden {|{"errcode": "M_UNKNOWN"}|}
    | Some json ->
      let event =
        Json_encoding.destruct Events.Pdu.encoding
          (Ezjsonm.value_from_string json) in
      let response =
        Response.make ~origin:t.server_name ~origin_server_ts:(time ())
          ~pdus:[event] ()
        |> Json_encoding.construct Response.encoding
        |> Ezjsonm.value_to_string in
      Dream.json response
end

module Transaction = struct
  (* Notes:
     - Verify if the room asking for the event is entitled to do so
     - Use the transaction ID
     - Apply the PDUs but ignore the EDUs
     - Verify the origin server
     - BROKEN: does not save the new previous event id
  *)
  let send t request =
    let open Send in
    let txn_id = Dream.param "txn_id" request in
    let%lwt body = Dream.body request in
    let transaction =
      Json_encoding.destruct Request.encoding (Ezjsonm.value_from_string body)
    in
    let pdus = Request.get_pdus transaction in
    let%lwt tree = Store.tree store in
    let f (tree, results) event =
      let event = compute_hash_and_sign t event in
      let event_id = compute_event_reference_hash event in
      let event_type = Events.Pdu.get_event_type event in
      let room_id = Events.Pdu.get_room_id event in
      (* need error handling *)
      let state_key = Events.Pdu.get_state_key event |> Option.get in
      let json_event =
        Json_encoding.construct Events.Pdu.encoding event
        |> Ezjsonm.value_to_string in
      let%lwt tree =
        Store.Tree.add tree
          (Store.Key.v ["rooms"; room_id; "state"; event_type; state_key])
          event_id in
      let%lwt tree =
        Store.Tree.add tree (Store.Key.v ["events"; event_id]) json_event in
      let full_event_id = "$" ^ event_id ^ ":" ^ Events.Pdu.get_origin event in
      Lwt.return
        ( tree,
          (full_event_id, Response.Pdu_processing_result.make ()) :: results )
    in
    let%lwt tree, results = Lwt_list.fold_left_s f (tree, []) pdus in
    (* saving update tree *)
    let message =
      Fmt.str "add transaction %s from %s" txn_id
        (Request.get_origin transaction) in
    let%lwt return =
      Store.set_tree ~info:(Helper.info t ~message) store (Store.Key.v []) tree
    in
    match return with
    | Ok () ->
      let response =
        Response.make ~pdus:results ()
        |> Json_encoding.construct Response.encoding
        |> Ezjsonm.value_to_string in
      Dream.json response
    | Error write_error ->
      Dream.error (fun m ->
          m "Write error: %a" (Irmin.Type.pp Store.write_error_t) write_error);
      Dream.json ~status:`Internal_Server_Error {|{"errcode": "M_UNKNOWN"}|}
end

module Backfill = struct
  (* Notes:
     - Verify if the room asking for the event is entitled to do so
     - Use the limit/do the pagination
     - Error handling
     - It's way too bad, needs a lot of rework in order to do less operations
  *)
  let get t request =
    let open Backfill in
    let _room_id = Dream.param "room_id" request in
    let v = Dream.queries "v" request in
    let _limit = Dream.query "limit" request in
    if List.length v == 0 then
      Dream.json ~status:`Forbidden {|{"errcode": "M_FORBIDDEN"}|}
    else
      let%lwt tree = Store.tree store in
      let rec f (event_ids, events) event_id =
        let event_id = Identifiers.Event_id.of_string_exn event_id in
        if List.exists (String.equal event_id) event_ids then
          Lwt.return (event_ids, events)
        else
          let%lwt json =
            Store.Tree.find tree @@ Store.Key.v ["events"; event_id] in
          match json with
          | None -> Lwt.return (event_ids, events)
          | Some json ->
            let event =
              Json_encoding.destruct Events.Pdu.encoding
                (Ezjsonm.value_from_string json) in
            let prev_event = Events.Pdu.get_prev_events event in
            Lwt_list.fold_left_s f
              (event_id :: event_ids, event :: events)
              prev_event in
      let%lwt _, events = Lwt_list.fold_left_s f ([], []) v in
      let response =
        Response.make ~origin:t.server_name ~origin_server_ts:(time ())
          ~pdus:events ()
        |> Json_encoding.construct Response.encoding
        |> Ezjsonm.value_to_string in
      Dream.json response
end

module Invite = struct
  (* Notes:
     - We disable the invitation, because no user should ever be able to invite
       someone in the room for now *)
  let invite _ =
    Lwt.return
      (Dream.response ~status:`Forbidden
         {|{"errcode": "M_FORBIDDEN", "error": "User cannot invite the target user."}|})
end

let router (t : Common_routes.t) =
  Dream.router
    [
      Dream.scope "/_matrix" []
        [
          Dream.scope "/federation" []
            [
              Dream.scope "/v1" []
                [
                  Dream.get "/version" placeholder;
                  Dream.put "/3pid/onbind" placeholder;
                  Dream.get "/openid/userinfo" placeholder;
                  Dream.scope "" [is_logged_server t]
                    [
                      Dream.put "/send/:txn_id" (Transaction.send t);
                      Dream.get "/event_auth/:room_id/:event_id" placeholder;
                      Dream.get "/backfill/:room_id" (Backfill.get t);
                      Dream.post "/get_missing_events/:room_id" placeholder;
                      Dream.get "/state/:room_id" placeholder;
                      Dream.get "/state_ids/:room_id" placeholder;
                      Dream.get "/event/:event_id" (Retrieve.get_event t);
                      Dream.get "/make_join/:room_id/:user_id" (Join.make t);
                      Dream.put "/send_join/:room_id/:event_id" placeholder;
                      Dream.put "/invite/:room_id/:event_id" Invite.invite;
                      Dream.get "/make_leave/:room_id/:user_id" placeholder;
                      Dream.put "/send_leave/:room_id/:event_id" placeholder;
                      Dream.put "/exchange_third_party_invite/:room_id"
                        placeholder;
                      Dream.get "/publicRooms" (Public_rooms.get t);
                      Dream.post "/publicRooms" placeholder;
                      Dream.scope "/query" []
                        [
                          Dream.get "/:query_type" placeholder;
                          Dream.get "/directory" placeholder;
                          Dream.get "/profile" placeholder;
                        ];
                      Dream.scope "/user" []
                        [
                          Dream.get "/devices/:user_id" placeholder;
                          Dream.scope "/keys" []
                            [
                              Dream.post "/claim" placeholder;
                              Dream.post "/query" placeholder;
                            ];
                        ];
                    ];
                ];
              Dream.scope "/v2" []
                [
                  Dream.scope "" [is_logged_server t]
                    [
                      Dream.put "/send_join/:room_id/:event_id" (Join.send t);
                      Dream.put "/invite/:room_id/:event_id" placeholder;
                      Dream.put "/send_leave/:room_id/:event_id" placeholder;
                    ];
                ];
            ];
          Dream.scope "/key/v2" []
            [
              Dream.get "/server" (Key.V2.direct_query t);
              Dream.get "/server/:key_id" (Key.V2.direct_query t);
              Dream.get "/query/:server_name/:key_id" placeholder;
              Dream.post "/query" (Key.V2.indirect_query t);
            ];
        ];
    ]
