# Number literals

beam-lisp reads numbers the way Clojure does.

| you write | you get | notes |
|---|---|---|
| `42` `-7` `+7` | integer | decimal |
| `0xD431` `0XD431` | `54321` | hexadecimal, either case of `x` and of the digits |
| `0666` | `438` | octal: a leading `0` followed by digits |
| `8r666` | `438` | radix form: `<base>r<digits>`, base 2 to 36 |
| `16rD431` `2r101` `36rZ` | `54321` `5` `35` | digits past 9 are letters, either case |
| `-0x10` `-16rFF` `-010` | `-16` `-255` `-8` | a sign works with every form |
| `7N` `0xFFN` | `7` `255` | the bigint suffix; every BEAM integer is already big |
| `1.5` `1e3` `2E-4` | float | |
| `1.5M` | exact decimal | see `exact-decimals.bl.md` |

## Octal

Write octal as `0666` or `8r666`. A file mode reads naturally either way:

```clojure
(File/chmod path 0644)
(File/chmod path 8r644)
```

`0o666` is not a number in Clojure or in beam-lisp. Neither is `08`, which has
a leading zero but a digit octal does not have.

## A token that starts with a digit is a number

`0o666`, `08`, `0b101` and `1x` are reader errors that point at the file, line
and column:

```
app.bl:2:10: invalid number literal: 0o666
```

A name can never start with a digit, so a typo in a number never becomes a
lookup of a var that does not exist.
