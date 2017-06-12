open! Core
open Re2.Std
module Crypto = Crypto.Cryptokit
module Hash = Crypto.Hash

let make_id () =
  sprintf !"<%s/%s+%{Uuid}@%s>"
    (Unix.getlogin ())
    (Sys.executable_name |> Filename.basename)
    (Uuid.create ())
    (Unix.gethostname ())

let utc_offset_string time ~zone =
  let utc_offset   = Time.utc_offset time ~zone in
  let is_utc       = Time.Span.(=) utc_offset Time.Span.zero in
  if is_utc
  then "Z"
  else
    String.concat
      [ (if Time.Span.(<) utc_offset Time.Span.zero then "-" else "+");
        Time.Ofday.to_string_trimmed
          (Time.Ofday.of_span_since_start_of_day (Time.Span.abs utc_offset));
      ]

let rfc822_date now =
  let zone = (force Time.Zone.local) in
  let offset_string =
    utc_offset_string ~zone now
    |> String.filter ~f:(fun c -> Char.(<>) c ':')
  in
  let now_string = Time.format now "%a, %d %b %Y %H:%M:%S" ~zone in
  sprintf "%s %s" now_string offset_string

let bigstring_shared_to_file data file =
  let open Async in
  Deferred.Or_error.try_with (fun () ->
    Writer.with_file file
      ~f:(fun w ->
        String_monoid.output_unix (Bigstring_shared.to_string_monoid data) w;
        Writer.flushed w))

let last_header t name = Headers.last (Email.headers t) name

let add_headers t headers' =
  Email.modify_headers t ~f:(fun headers -> Headers.add_all headers headers')

let set_header_at_bottom t ~name ~value =
  Email.modify_headers t ~f:(Headers.set_at_bottom ~name ~value)

module Expert = struct
  let content ~whitespace ~extra_headers ~encoding body =
    let headers =
      [ "Content-Transfer-Encoding",
        (Octet_stream.Encoding.to_string (encoding :> Octet_stream.Encoding.t))
      ] @ extra_headers
    in
    let headers = Headers.of_list ~whitespace headers in
    let octet_stream =
      body
      |> Bigstring_shared.of_string
      |> Octet_stream.encode ~encoding
    in
    Email_content.to_email ~headers (Data octet_stream)

  let multipart ~whitespace ~content_type ~extra_headers parts =
    let boundary = Boundary.generate () in
    let headers =
      [ "Content-Type", (sprintf !"%s; boundary=\"%{Boundary}\"" content_type boundary)
      ] @ extra_headers
    in
    let headers = Headers.of_list ~whitespace headers in
    let multipart =
      { Email_content.Multipart.boundary
      ; prologue=None
      ; epilogue=None
      ; container_headers=Headers.empty
      ; parts }
    in
    Email_content.to_email ~headers (Multipart multipart)

  let create_raw
        ?(from=Email_address.local_address () |> Email_address.to_string)
        ~to_
        ?(cc=[])
        ?(reply_to=[])
        ~subject
        ?id
        ?in_reply_to
        ?date
        ?auto_generated
        ?(extra_headers=[])
        ?(attachments=[])
        content
    =
    let id = match id with
      | None ->  make_id ()
      | Some id -> id
    in
    let date = match date with
      | None -> rfc822_date (Time.now ())
      | Some date -> date
    in
    let headers =
      extra_headers
      @ [ "From", from ]
      @ (if List.is_empty to_ then []
         else [ "To", String.concat to_ ~sep:",\n\t" ])
      @ (if List.is_empty cc then []
         else [ "Cc", String.concat cc ~sep:",\n\t" ])
      @ (if List.is_empty reply_to then []
         else [ "Reply-To", String.concat reply_to ~sep:",\n\t" ])
      @ [ "Subject", subject ]
      @ [ "Message-Id", id ]
      @ (match in_reply_to with
        | None -> []
        | Some in_reply_to -> [ "In-Reply-To", in_reply_to ])
      @ (match auto_generated with
        | None -> []
        | Some () ->
          [ "Auto-Submitted", "auto-generated"
          ; "Precedence", "bulk" ])
      @ [ "Date", date ]
    in
    match attachments with
    | [] ->
      add_headers content headers
    | attachments ->
      multipart
        ~whitespace:`Normalize
        ~content_type:"multipart/mixed"
        ~extra_headers:headers
        ((set_header_at_bottom content ~name:"Content-Disposition" ~value:"inline")
         :: List.map attachments ~f:(fun (name,content) ->
           let content_type =
             last_header content "Content-Type"
             |> Option.value ~default:"application/x-octet-stream"
           in
           set_header_at_bottom content ~name:"Content-Type"
             ~value:(sprintf "%s; name=%s" content_type (Mimestring.quote name))
           |> set_header_at_bottom ~name:"Content-Disposition"
                ~value:(sprintf "attachment; filename=%s" (Mimestring.quote name))))
end

module Mimetype = struct
  type t = string
  let text = "text/plain"
  let html = "text/html"
  let pdf = "application/pdf"
  let jpg = "image/jpeg"
  let png = "image/png"

  let multipart_mixed = "multipart/mixed"
  let multipart_alternative = "multipart/alternative"
  let multipart_related = "multipart/related"

  let from_extension ext =
    Magic_mime_external.Mime_types.map_extension ext

  let from_filename file =
    Magic_mime_external.Magic_mime.lookup file

  let guess_encoding : t -> Octet_stream.Encoding.known = function
    | "text/plain"
    | "text/html" -> `Quoted_printable
    | _ -> `Base64
end

type attachment_name = string

module Attachment = struct
  type t =
    { headers : Headers.t
    ; filename : string
    ; embedded_email : Email.t option
    (* These are expensive operations. Ensure they are only computed once, and
       lazily. *)
    ; raw_data : Bigstring_shared.t Or_error.t Lazy.t
    ; md5      : string Or_error.t Lazy.t
    } [@@deriving fields]

  let raw_data t = Lazy.force t.raw_data
  let md5 t      = Lazy.force t.md5

  let to_hex digest =
    let result = String.create (String.length digest * 2) in
    let hex = "0123456789ABCDEF" in
    for i = 0 to String.length digest - 1 do
      let c = int_of_char digest.[i] in
      result.[2*i] <- hex.[c lsr 4];
      result.[2*i+1] <- hex.[c land 0xF]
    done;
    result

  let of_content' ?embedded_email ~headers ~filename content =
    let raw_data =
      lazy (
        Or_error.try_with (fun () ->
          Octet_stream.decode (Lazy.force content)
          |> Option.value_exn)
      )
    in
    let md5 =
      lazy (
        match Lazy.force raw_data with
        | Error _ as err -> err
        | Ok data ->
          Or_error.try_with (fun () ->
            Crypto.hash_string (Hash.md5 ())
              (Bigstring_shared.to_string data)
            |> to_hex)
      )
    in
    { headers; filename; embedded_email; raw_data; md5 }

  let of_content ~headers ~filename content =
    of_content' ~headers ~filename (lazy content)

  let of_embedded_email ~headers ~filename embedded_email =
    let content =
      lazy begin
        Email.to_bigstring_shared embedded_email
        |> Octet_stream.of_bigstring_shared
             ~encoding:(Octet_stream.Encoding.of_headers_or_default headers)
      end
    in
    of_content' ~embedded_email ~headers ~filename content

  let to_file t file =
    match raw_data t with
    | Error _ as err -> Async.return err
    | Ok data -> bigstring_shared_to_file data file
end

module Content = struct
  type t = Email.t [@@deriving bin_io, sexp_of]
  let of_email = ident

  let create ~content_type ?(encoding=Mimetype.guess_encoding content_type) ?(extra_headers=[]) content =
    Expert.content
      ~whitespace:`Normalize
      ~extra_headers:(extra_headers @ [ "Content-Type", content_type ])
      ~encoding
      content

  let of_file ?content_type ?encoding ?extra_headers file =
    let open Async in
    Reader.file_contents file
    >>| fun content ->
    let content_type = match content_type with
      | None -> Mimetype.from_filename file
      | Some content_type -> content_type
    in
    create ~content_type ?encoding ?extra_headers content

  let html ?(encoding=`Quoted_printable) ?extra_headers content =
    create ?extra_headers ~content_type:Mimetype.html ~encoding content

  let text ?(encoding=`Quoted_printable) ?extra_headers content =
    create ?extra_headers ~content_type:Mimetype.text ~encoding content

  let create_multipart ?(extra_headers=[]) ~content_type = function
    | [] -> failwith "at least one part is required"
    | [content] ->
      add_headers content extra_headers
    | parts ->
      Expert.multipart
        ~whitespace:`Normalize
        ~content_type
        ~extra_headers
        parts

  let alternatives ?extra_headers =
    create_multipart ?extra_headers ~content_type:Mimetype.multipart_alternative

  let mixed ?extra_headers =
    create_multipart ?extra_headers ~content_type:Mimetype.multipart_mixed

  let with_related ?(extra_headers=[]) ~resources t =
    Expert.multipart
      ~whitespace:`Normalize
      ~content_type:Mimetype.multipart_related
      ~extra_headers
      (add_headers t [ "Content-Disposition", "inline" ]
       :: List.map resources ~f:(fun (name,content) ->
         add_headers content [ "Content-Id", sprintf "<%s>" name ]))

  let parse_last_header t name =
    match last_header t name with
    | None -> None
    | Some str ->
      match String.split str ~on:';'
            |> List.map ~f:String.strip with
      | [] -> None
      | v::args ->
        let args = List.map args ~f:(fun str ->
          match String.lsplit2 str ~on:'=' with
          | None -> str, None
          | Some (k,v) -> String.strip k, Some (String.strip v))
        in
        Some (v,args)

  let content_type t =
    let open Option.Monad_infix in
    (parse_last_header t "Content-Type" >>| fst)
    |> Option.value ~default:"application/x-octet-stream"

  let attachment_name t =
    let open Option.Monad_infix in
    let quoted_re = Re2.create "\"(.*)\"" in
    let unquote name =
      let f name =
        match
          Or_error.try_with (fun () ->
            Re2.replace_exn (Or_error.ok_exn quoted_re) name ~f:(fun match_ ->
              Re2.Match.get_exn ~sub:(`Index 1) match_))
        with
        | Error _ -> name
        | Ok name -> name
      in
      Option.map name ~f
    in
    Option.first_some
      begin
        parse_last_header t "Content-Disposition"
        >>= fun (disp, args) ->
        if String.Caseless.equal disp "attachment" then
          List.find_map args ~f:(fun (k,v) ->
            if String.Caseless.equal k "filename" then (unquote v) else None)
        else
          None
      end
      begin
        parse_last_header t "Content-Type"
        >>= fun (_, args) ->
        List.find_map args ~f:(fun (k,v) ->
          if String.Caseless.equal k "name" then (unquote v) else None)
      end

  let related_part_cid t =
    let open Option.Monad_infix in
    last_header t "Content-Id"
    >>| String.strip
    >>| fun str ->
    begin
      String.chop_prefix str ~prefix:"<"
      >>= String.chop_suffix ~suffix:">"
    end |> Option.value ~default:str

  let content_disposition t =
    match parse_last_header t "Content-Disposition" with
    | None -> `Inline
    | Some (disp,_) ->
      if String.Caseless.equal disp "inline" then `Inline
      else if String.Caseless.equal disp "attachment" then
        `Attachment (attachment_name t |> Option.value ~default:"unnamed-attachment")
      else match attachment_name t with
        | None -> `Inline
        | Some name -> `Attachment name

  let parts t =
    match Email_content.parse t with
    | Error _ -> None
    | Ok (Email_content.Multipart ts) -> Some ts.Email_content.Multipart.parts
    | Ok (Message _) -> None
    | Ok (Data _) -> None

  let content t =
    match Email_content.parse t with
    | Error _ -> None
    | Ok (Email_content.Multipart _) -> None
    | Ok (Message _) -> None
    | Ok (Data data) -> Some data

  let rec inline_parts t =
    match parts t with
    | Some parts ->
      if String.Caseless.equal (content_type t) Mimetype.multipart_alternative then
        (* multipart/alternative is special since an aplication is expected to
           present/process any one of the alternative parts. The logic for picking
           the 'correct' alternative is application dependant so leaving this to
           to users (e.g. first one that parses) *)
        [t]
      else
        List.concat_map parts ~f:inline_parts
    | None ->
      match content_disposition t with
      | `Inline -> [t]
      | `Attachment _ -> []

  let rec alternative_parts t =
    match parts t with
    | None -> [t]
    | Some ts ->
      if String.Caseless.equal (content_type t) Mimetype.multipart_alternative then
        List.concat_map ts ~f:alternative_parts
      else [t]

  let rec all_related_parts t =
    let get_cid t =
      Option.map (related_part_cid t) ~f:(fun cid -> [cid, t])
      |> Option.value ~default:[]
    in
    (get_cid t) @
    (parts t
     |> Option.value ~default:[]
     |> List.concat_map ~f:all_related_parts)

  let find_related t name =
    List.find (all_related_parts t) ~f:(fun (cid, _t) ->
      String.equal cid name)
    |> Option.map ~f:snd

  let to_file t file =
    let open Async in
    match content t with
    | None -> Deferred.Or_error.errorf "The payload of this email is ambigous, you
                  you should decompose the email further"
    | Some content ->
      match Octet_stream.decode content with
      | None -> Deferred.Or_error.errorf "The message payload used an unknown encoding"
      | Some content -> bigstring_shared_to_file content file
end

type t = Email.t [@@deriving sexp_of]

let create
      ?from
      ~to_
      ?cc
      ?reply_to
      ~subject
      ?id
      ?in_reply_to
      ?date
      ?auto_generated
      ?extra_headers
      ?attachments
      content
  =
  Expert.create_raw
    ?from:(Option.map from ~f:Email_address.to_string)
    ~to_:(List.map to_ ~f:Email_address.to_string)
    ?cc:(Option.map cc ~f:(List.map ~f:Email_address.to_string))
    ?reply_to:(Option.map reply_to ~f:(List.map ~f:Email_address.to_string))
    ~subject
    ?id
    ?in_reply_to
    ?date:(Option.map date ~f:rfc822_date)
    ?auto_generated
    ?extra_headers
    ?attachments
    content

let decode_last_header name ~f t =
  Option.bind
    (last_header t name)
    ~f:(fun v -> Option.try_with (fun () -> f v))

let from =
  decode_last_header "From" ~f:Email_address.of_string_exn

let to_ =
  decode_last_header "To" ~f:Email_address.list_of_string_exn

let cc =
  decode_last_header "Cc" ~f:Email_address.list_of_string_exn

let subject =
  decode_last_header "Subject" ~f:Fn.id

let id =
  decode_last_header "Message-Id" ~f:Fn.id

let all_related_parts = Content.all_related_parts
let find_related = Content.find_related
let inline_parts =  Content.inline_parts

let parse_attachment ?container_headers t =
  match Content.content_disposition t with
  | `Inline -> None
  | `Attachment filename ->
    let headers = Email.headers t in
    match Email_content.parse ?container_headers t with
    | Error _ -> None
    | Ok (Email_content.Multipart _) -> None
    | Ok (Message email) ->
      Some (Attachment.of_embedded_email ~headers ~filename email)
    | Ok (Data content) ->
      Some (Attachment.of_content ~headers ~filename content)
;;

let rec map_file_attachments ?container_headers t ~f =
  let open Async in
  match Email_content.parse ?container_headers t with
  | Error _ -> return t
  | Ok (Data _data) ->
    begin match parse_attachment ?container_headers t with
    | None -> return t
    | Some attachment ->
      match%map f attachment with
      | `Keep -> t
      | `Replace t -> t
    end
  | Ok (Message message) ->
    let%map message' = map_file_attachments message ?container_headers:None ~f in
    Email_content.set_content t (Message message')
  | Ok (Multipart (mp : Email_content.Multipart.t)) ->
    let%map parts' =
      Deferred.List.map mp.parts
        ~f:(map_file_attachments ~f ~container_headers:mp.container_headers)
    in
    let mp' = {mp with Email_content.Multipart.parts = parts'} in
    Email_content.set_content t (Multipart mp')

let rec all_attachments ?container_headers t =
  match Email_content.parse ?container_headers t with
  | Error _ -> []
  | Ok (Data _data) ->
    Option.value_map ~default:[] (parse_attachment ?container_headers t) ~f:(fun a -> [a])
  | Ok (Message message) ->
    Option.value_map ~default:[] (parse_attachment ?container_headers t) ~f:(fun a -> [a])
    @ (all_attachments ?container_headers:None message)
  | Ok (Multipart (mp : Email_content.Multipart.t)) ->
    List.concat_map mp.parts
      ~f:(all_attachments ~container_headers:mp.container_headers)
;;

let map_file_attachments = map_file_attachments ?container_headers:None
let all_attachments = all_attachments ?container_headers:None

let find_attachment t name =
  List.find (all_attachments t) ~f:(fun attachment ->
    String.equal (Attachment.filename attachment) name)
;;
