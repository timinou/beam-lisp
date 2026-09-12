// tree-sitter grammar for Beam Lisp (.bl) — a Clojure-reader dialect on the
// BEAM. Forked from sogaiu/tree-sitter-clojure (CC0); the reader contract is
// priv/boot/reader.bl. Aim: parse everything the bl reader accepts, loosely
// (superset tolerated) — per tree-sitter folk advice.
//
// Deltas vs tree-sitter-clojure:
//   * kwd_lit gains `:"string"` — the bl reader's keyword-string form
//     (read-form: head 58 followed by 34 reads a keyword from a string).
//   * language name is `beamlisp`.

function regex(...patts) {
  return RegExp(patts.join(""));
}

// java.lang.Character.isWhitespace AND comma
const WHITESPACE_CHAR =
      regex("[",
            "\\f\\n\\r\\t, ",
            "\\u000B\\u001C\\u001D\\u001E\\u001F",
            "\\u2028\\u2029\\u1680",
            "\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2008",
            "\\u2009\\u200a\\u205f\\u3000",
            "]");

const WHITESPACE =
      token(repeat1(WHITESPACE_CHAR));

const COMMENT =
      token(regex('(;|#!).*\n?'));

const DIGIT =
      regex('[0-9]');

const ALPHANUMERIC =
      regex('[0-9a-zA-Z]');

const HEX_DIGIT =
      regex('[0-9a-fA-F]');

const OCTAL_DIGIT =
      regex('[0-7]');

const HEX_NUMBER =
      seq("0",
          regex('[xX]'),
          repeat1(HEX_DIGIT),
          optional("N"));

const OCTAL_NUMBER =
      seq("0",
          repeat1(OCTAL_DIGIT),
          optional("N"));

const RADIX_NUMBER =
      seq(repeat1(DIGIT),
          regex('[rR]'),
          repeat1(ALPHANUMERIC));

const RATIO =
      seq(repeat1(DIGIT),
          "/",
          repeat1(DIGIT));

const DOUBLE =
      seq(repeat1(DIGIT),
          optional(seq(".",
                       repeat(DIGIT))),
          optional(seq(regex('[eE]'),
                       optional(regex('[+-]')),
                       repeat1(DIGIT))),
          optional("M"));

const INTEGER =
      seq(repeat1(DIGIT),
          optional(regex('[MN]')));

const NUMBER =
      token(prec(10, seq(optional(regex('[+-]')),
                         choice(HEX_NUMBER,
                                OCTAL_NUMBER,
                                RADIX_NUMBER,
                                RATIO,
                                DOUBLE,
                                INTEGER))));

const NIL =
      token('nil');

const BOOLEAN =
      token(choice('false',
                   'true'));

// bl tokens are bounded ONLY by whitespace, comma, ()[]{}", and ;
// (priv/boot/reader.bl `delimiters`). Unlike Clojure, @ ~ ^ ` # ' \ and
// digits are all legal INSIDE a token — e.g. :~similar, foo@bar, don't.
const KEYWORD_HEAD =
      regex("[^",
            "\\f\\n\\r\\t ",
            "()",
            "\\[\\]",
            "{}",
            '"',
            ";",
            ",:/",
            "\\u000B\\u001C\\u001D\\u001E\\u001F",
            "\\u2028\\u2029\\u1680",
            "\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2008",
            "\\u2009\\u200a\\u205f\\u3000",
            "]");

const KEYWORD_BODY =
      choice(regex("[:]"), KEYWORD_HEAD);

const KEYWORD_NAMESPACED_BODY =
      token(repeat1(choice(regex("[:/]"), KEYWORD_HEAD)));

const KEYWORD_NO_SIGIL =
      token(seq(KEYWORD_HEAD,
                repeat(KEYWORD_BODY)));

const KEYWORD_MARK =
      token(":");

const AUTO_RESOLVE_MARK =
      token("::");

const STRING =
      token(seq('"',
                repeat(regex('[^"\\\\]')),
                repeat(seq("\\",
                           regex("."),
                           repeat(regex('[^"\\\\]')))),
                '"'));

const OCTAL_CHAR =
      seq("o",
          choice(seq(DIGIT, DIGIT, DIGIT),
                 seq(DIGIT, DIGIT),
                 seq(DIGIT)));

const NAMED_CHAR =
      choice("backspace",
             "formfeed",
             "newline",
             "return",
             "space",
             "tab");

const UNICODE =
      seq("u",
          HEX_DIGIT,
          HEX_DIGIT,
          HEX_DIGIT,
          HEX_DIGIT);

const ANY_CHAR =
      regex('.|\n');

const CHARACTER =
      token(seq("\\",
                choice(OCTAL_CHAR,
                       NAMED_CHAR,
                       UNICODE,
                       ANY_CHAR)));

// head keeps excluding form-head chars so quote/deref/unquote/meta/#
// dispatch lex as reader macros; digits ARE legal token heads in bl
// (classify falls back to symbol when whole-number fails).
const SYMBOL_HEAD =
      regex("[^",
            "\\f\\n\\r\\t ",
            "/",
            "()\\[\\]{}",
            '"',
            "@~^;`",
            "\\\\",
            ",:#'",
            "\\u000B\\u001C\\u001D\\u001E\\u001F",
            "\\u2028\\u2029\\u1680",
            "\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2008",
            "\\u2009\\u200a\\u205f\\u3000",
            "]");

const NS_DELIMITER =
      token("/");

// everything a bl token body may carry past its head char
const SYMBOL_BODY_EXTRA =
      regex("[:#'0-9~@^`\\\\]");

const SYMBOL_BODY =
      choice(SYMBOL_HEAD,
             SYMBOL_BODY_EXTRA);

const SYMBOL_NAMESPACED_NAME =
      token(repeat1(choice(SYMBOL_HEAD,
                           regex("[/]"),
                           SYMBOL_BODY_EXTRA)));

const SYMBOL =
      token(seq(SYMBOL_HEAD,
                repeat(SYMBOL_BODY)));

module.exports = grammar({
  name: 'beamlisp',

  extras: $ =>
  [],

  conflicts: $ =>
  [],

  inline: $ =>
  [$._kwd_leading_slash,
   $._kwd_just_slash,
   $._kwd_qualified,
   $._kwd_unqualified,
   $._kwd_str,
   $._kwd_marker,
   $._sym_qualified,
   $._sym_unqualified],

  rules: {
    // THIS MUST BE FIRST -- even though this doesn't look like it matters
    source: $ =>
    repeat(choice($._form,
                  $._gap)),

    _gap: $ =>
    choice($._ws,
           $.comment,
           $.dis_expr),

    _ws: $ =>
    WHITESPACE,

    comment: $ =>
    COMMENT,

    dis_expr: $ =>
    seq(field('marker', "#_"),
        repeat($._gap),
        field('value', $._form)),

    _form: $ =>
    choice($.num_lit, // atom-ish
           $.kwd_lit,
           $.str_lit,
           $.char_lit,
           $.nil_lit,
           $.bool_lit,
           $.sym_lit,
           // basic collection-ish
           $.list_lit,
           $.map_lit,
           $.vec_lit,
           // dispatch reader macros
           $.set_lit,
           $.anon_fn_lit,
           $.regex_lit,
           $.read_cond_lit,
           $.splicing_read_cond_lit,
           $.ns_map_lit,
           $.var_quoting_lit,
           $.sym_val_lit,
           $.evaling_lit,
           $.tagged_or_ctor_lit,
           // some other reader macros
           $.derefing_lit,
           $.quoting_lit,
           $.syn_quoting_lit,
           $.unquote_splicing_lit,
           $.unquoting_lit),

    num_lit: $ =>
    NUMBER,

    kwd_lit: $ =>
    choice($._kwd_leading_slash,
           $._kwd_just_slash,
           $._kwd_qualified,
           $._kwd_unqualified,
           $._kwd_str),

    // (namespace :/usr/bin/env) ; => ""
    // (name :/usr/bin/env) ; => "usr/bin/env"
    _kwd_leading_slash: $ =>
    seq(field('marker', $._kwd_marker),
        field('delimiter', NS_DELIMITER),
        field('name', alias(KEYWORD_NAMESPACED_BODY, $.kwd_name))),

    // (namespace :/) ;=> nil
    // (name :/) ;=> "/"
    _kwd_just_slash: $ =>
    seq(field('marker', $._kwd_marker),
        field('name', alias(NS_DELIMITER, $.kwd_name))),

    _kwd_qualified: $ =>
    prec(2, seq(field('marker', $._kwd_marker),
                field('namespace', alias(KEYWORD_NO_SIGIL, $.kwd_ns)),
                field('delimiter', NS_DELIMITER),
                field('name', alias(KEYWORD_NAMESPACED_BODY, $.kwd_name)))),

    _kwd_unqualified: $ =>
    prec(1, seq(field('marker', $._kwd_marker),
                field('name', alias(KEYWORD_NO_SIGIL, $.kwd_name)))),

    // bl-specific: :"a keyword from a string" — the bl reader (head 58 then
    // 34) reads the string body as the keyword name.
    _kwd_str: $ =>
    seq(field('marker', KEYWORD_MARK),
        field('name', $.str_lit)),

    _kwd_marker: $ =>
    choice(KEYWORD_MARK, AUTO_RESOLVE_MARK),

    str_lit: $ =>
    STRING,

    char_lit: $ =>
    CHARACTER,

    nil_lit: $ =>
    NIL,

    bool_lit: $ =>
    BOOLEAN,

    sym_lit: $ =>
    seq(repeat($._metadata_lit),
        choice($._sym_qualified, $._sym_unqualified)),

    _sym_qualified: $ =>
    prec(1, seq(field("namespace", alias(SYMBOL, $.sym_ns)),
                field("delimiter", NS_DELIMITER),
                field("name", alias(SYMBOL_NAMESPACED_NAME, $.sym_name)))),

    _sym_unqualified: $ =>
    field('name', alias(choice(NS_DELIMITER, // division symbol
                               SYMBOL),
                        $.sym_name)),

    _metadata_lit: $ =>
    seq(choice(field("meta", $.meta_lit),
               field("old_meta", $.old_meta_lit)),
        optional(repeat($._gap))),

    meta_lit: $ =>
    seq(field('marker', "^"),
        repeat($._gap),
        field('value', $._form)),

    old_meta_lit: $ =>
    seq(field('marker', "#^"),
        repeat($._gap),
        field('value', $._form)),

    list_lit: $ =>
    seq(repeat($._metadata_lit),
        $._bare_list_lit),

    _bare_list_lit: $ =>
    seq(field('open', "("),
        repeat(choice(field('value', $._form),
                      $._gap)),
        field('close', ")")),

    map_lit: $ =>
    seq(repeat($._metadata_lit),
        $._bare_map_lit),

    _bare_map_lit: $ =>
    seq(field('open', "{"),
        repeat(choice(field('value', $._form),
                      $._gap)),
        field('close', "}")),

    vec_lit: $ =>
    seq(repeat($._metadata_lit),
        $._bare_vec_lit),

    _bare_vec_lit: $ =>
    seq(field('open', "["),
        repeat(choice(field('value', $._form),
                      $._gap)),
        field('close', "]")),

    set_lit: $ =>
    seq(repeat($._metadata_lit),
        $._bare_set_lit),

    _bare_set_lit: $ =>
    seq(field('marker', "#"),
        field('open', "{"),
        repeat(choice(field('value', $._form),
                      $._gap)),
        field('close', "}")),

    anon_fn_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "#"),
        $._bare_list_lit),

    regex_lit: $ =>
    seq(field('marker', "#"),
        STRING),

    read_cond_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "#?"),
        // whitespace possible, but neither comment nor discard
        repeat($._ws),
        $._bare_list_lit),

    splicing_read_cond_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "#?@"),
        repeat($._ws),
        $._bare_list_lit),

    auto_res_mark: $ =>
    AUTO_RESOLVE_MARK,

    ns_map_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "#"),
        field('prefix', choice($.auto_res_mark,
                               $.kwd_lit)),
        repeat($._gap),
        $._bare_map_lit),

    var_quoting_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "#'"),
        repeat($._gap),
        field('value', $._form)),

    sym_val_lit: $ =>
    seq(field('marker', "##"),
        repeat($._gap),
        field('value', $._form)),

    evaling_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "#="),
        repeat($._gap),
        field('value', choice($.list_lit,
                              $.read_cond_lit,
                              $.sym_lit))),

    // #d "2026-09-08"   (registered data readers)
    // #my.Record{:a 1}  (record literals)
    tagged_or_ctor_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "#"),
        repeat($._gap),
        field('tag', $.sym_lit),
        repeat($._gap),
        field('value', $._form)),

    derefing_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "@"),
        repeat($._gap),
        field('value', $._form)),

    quoting_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "'"),
        repeat($._gap),
        field('value', $._form)),

    syn_quoting_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "`"),
        repeat($._gap),
        field('value', $._form)),

    unquote_splicing_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "~@"),
        repeat($._gap),
        field('value', $._form)),

    unquoting_lit: $ =>
    seq(repeat($._metadata_lit),
        field('marker', "~"),
        repeat($._gap),
        field('value', $._form)),
  }
});
