//! Token definitions shared between scanner and parser.
//! Simple, flat token type — no logic.

pub const TokenType = enum(u8) {
    // ---- single-character ----
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
    comma,
    colon,
    dot,
    at,
    minus,
    plus,
    semicolon,
    slash,
    star,
    question_mark, // ? (has-attr and default params)
    dollar_curly, // ${

    // ---- compound ----
    bang,
    bang_equal,
    equal,
    equal_equal,
    greater,
    greater_equal,
    less,
    less_equal,
    amp_amp, // &&
    pipe_pipe, // ||
    pipe_forward, // |>
    pipe_backward, // <|
    double_plus, // ++
    double_slash, // // (update operator)
    ellipsis, // ...
    arrow, // ->

    // ---- literals ----
    identifier,
    string,
    integer,
    float_val,
    path,
    uri,
    search_path,

    // ---- keywords ----
    kw_if,
    kw_then,
    kw_else,
    kw_assert,
    kw_with,
    kw_let,
    kw_in,
    kw_rec,
    kw_inherit,
    kw_or,

    // ---- special ----
    error_token,
    eof,
};

pub const Token = struct {
    type: TokenType,
    /// Offset and length into the source.
    offset: u32,
    len: u32,
    // No line number: tokens are produced in the parse hot loop, and line
    // numbers are only needed for diagnostics (cold) — recompute them from
    // the offset there (see `Parser.tokenLine`). This also frees the
    // scanner from counting newlines at all.
};
