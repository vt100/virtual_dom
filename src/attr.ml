open Base
open Js_of_ocaml

(** This has 2 kinds of constructors. {v
      - First class constructors for properties / attributes for which we
        have written first class ocaml representations (so far only Style
        and Class)

      - And those which we immediatly convert into Js called Raw, which
        in turn has to cases:
        - Property for properties on the DOM
        - Attribute for attributes on the DOM
    v}

    Generally speaking one should avoid creating a property or attribute
    for something for which we have a first class representation.
*)

module Raw : sig
  type t

  (** {2 Attribute creation functions *)
  val create : string -> string -> t

  val create_float : string -> float -> t

  (** {2 Property creation functions *)
  val property : string -> Js.Unsafe.any -> t

  val string_property : string -> string -> t
  val list_to_obj : t list -> < > Js.t
end = struct
  type t =
    | Property of string * Js.Unsafe.any
    | Attribute of string * Js.Unsafe.any

  let create name value = Attribute (name, Js.Unsafe.inject (Js.string value))

  let create_float name value =
    Attribute (name, Js.Unsafe.inject (Js.number_of_float value)##toString)
  ;;

  let property name value = Property (name, value)
  let string_property name value = Property (name, Js.Unsafe.inject (Js.string value))

  let list_to_obj attrs =
    (* When input elements have their value set to what it already is
       the cursor gets moved to the end of the field even when the user
       is editing in the middle. SoftSetHook (from ./soft-set-hook.js)
       compares before setting, avoiding the problem just like in
       https://github.com/Matt-Esch/virtual-dom/blob/947ecf92b67d25bb693a0f625fa8e90c099887d5/virtual-hyperscript/index.js#L43-L51

       note that Elm's virtual-dom includes a workaround for this so
       if we switch to that the workaround here will be unnecessary.
       https://github.com/elm-lang/virtual-dom/blob/17b30fb7de48672565d6227d33c0176f075786db/src/Native/VirtualDom.js#L434-L439
    *)
    let softSetHook x = Js.Unsafe.global ## SoftSetHook x in
    let attrs_obj = Js.Unsafe.obj [||] in
    List.iter
      ~f:(function
        | Property (name, value) ->
          let value = if String.( = ) name "value" then softSetHook value else value in
          Js.Unsafe.set attrs_obj (Js.string name) value
        | Attribute (name, value) ->
          if not (Js.Optdef.test attrs_obj##.attributes)
          then attrs_obj##.attributes := Js.Unsafe.obj [||];
          Js.Unsafe.set attrs_obj##.attributes (Js.string name) value)
      attrs;
    attrs_obj
  ;;
end

type t =
  | Style of Css.t
  | Class of (string, String.comparator_witness) Set.t
  | Raw of Raw.t

let to_style = function
  | Style s -> Some s
  | Class _ | Raw _ -> None
;;

let style css = Style css

let style_to_raw css =
  let props = Css.to_string_list css in
  let obj = Js.Unsafe.obj [||] in
  List.iter ~f:(fun (k, v) -> Js.Unsafe.set obj (Js.string k) (Js.string v)) props;
  Raw.property "style" obj
;;

let valid_class_name s =
  let invalid = String.is_empty s || String.exists s ~f:Char.is_whitespace in
  not invalid
;;

let%test "valid" = valid_class_name "foo-bar"
let%test "invalid-empty" = not (valid_class_name "")
let%test "invalid-space" = not (valid_class_name "foo bar")

let class_ classname =
  if not (valid_class_name classname)
  then raise_s [%message "invalid classname" (classname : string)];
  Class (Set.singleton (module String) classname)
;;

let classes' classes = Class classes

let classes classnames =
  if not (List.for_all ~f:valid_class_name classnames)
  then raise_s [%message "invalid classnames" (classnames : string list)];
  classes' (Set.of_list (module String) classnames)
;;

let to_class = function
  | Class cs -> Some cs
  | Style _ | Raw _ -> None
;;

let class_to_raw classes =
  Raw.create "class" (String.concat (Set.to_list classes) ~sep:" ")
;;

let create name value = Raw (Raw.create name value)
let create_float name value = Raw (Raw.create_float name value)
let property name value = Raw (Raw.property name value)
let string_property name value = Raw (Raw.string_property name value)
let id s = create "id" s
let name s = create "name" s
let href r = create "href" r
let checked = create "checked" ""
let selected = create "selected" ""
let disabled = create "disabled" ""
let placeholder x = create "placeholder" x
let autofocus b = create "autofocus" (Bool.to_string b)
let for_ x = create "for" x
let type_ x = create "type" x
let value x = create "value" x
let tabindex x = create "tabindex" (Int.to_string x)

let on event convert_to_vdom_event : t =
  let f e =
    Event.Expert.handle e (convert_to_vdom_event e);
    Js._true
  in
  property ("on" ^ event) (Js.Unsafe.inject (Dom.handler f))
;;

let on_focus = on "focus"
let on_blur = on "blur"
let on_click = on "click"
let on_contextmenu = on "contextmenu"
let on_double_click = on "dblclick"
let on_mousemove = on "mousemove"
let on_mouseup = on "mouseup"
let on_mousedown = on "mousedown"
let on_mouseenter = on "mouseenter"
let on_mouseleave = on "mouseleave"
let on_mouseover = on "mouseover"
let on_mouseout = on "mouseout"
let on_keyup = on "keyup"
let on_keypress = on "keypress"
let on_keydown = on "keydown"
let const_ignore _ = Event.Ignore

class type value_element =
  object
    inherit Dom_html.element

    method value : Js.js_string Js.t Js.prop
  end

type value_coercion = Dom_html.element Js.t -> value_element Js.t Js.opt

let run_coercion coercion target prev =
  match prev with
  | Some _ -> prev
  | None -> Js.Opt.to_option (coercion target)
;;

let coerce_value_element target =
  let open Dom_html.CoerceTo in
  None
  |> run_coercion (input :> value_coercion) target
  |> run_coercion (select :> value_coercion) target
  |> run_coercion (textarea :> value_coercion) target
;;

let on_input_event event handler =
  on event (fun ev ->
    Js.Opt.case ev##.target const_ignore (fun target ->
      Option.value_map
        (coerce_value_element target)
        ~default:Event.Ignore
        ~f:(fun target ->
          let text = Js.to_string target##.value in
          handler ev text)))
;;

let on_change = on_input_event "change"
let on_input = on_input_event "input"

let to_raw = function
  | Raw r -> r
  | Style css -> style_to_raw css
  | Class classes -> class_to_raw classes
;;

let list_to_obj l = Raw.list_to_obj (List.map l ~f:to_raw)
