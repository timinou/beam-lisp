# W0-P1f — prove the self-grafting arithmetic from INSIDE a running drop.
#
# Runs inside a drop built by the HEAD launcher, where BL_BIN names the drop
# file. This is the exact algorithm `bl pack` must implement:
#   drop = launcher ++ payload ++ trailer(56)
#   read the trailer -> offset (== launcher length), len, sha256
#   launcher prefix = bytes [0, offset)
#   verify sha256(payload) == trailer.sha256
#
# Env: BL_SELF (optional) — a second drop file to parse for comparison.

path = System.get_env("BL_BIN") || raise("BL_BIN not set — launcher predates the change")
data = File.read!(path)
n = byte_size(data)
IO.puts("P1f self=#{path}")
IO.puts("P1f size=#{n}")

<<offset::little-64, len::little-64, sha::binary-32, os, arch, ver::little-16, magic::binary-4>> =
  binary_part(data, n - 56, 56)

launcher = binary_part(data, 0, offset)
payload = binary_part(data, offset, len)
digest = :crypto.hash(:sha256, payload)

IO.puts("P1f magic=#{magic} version=#{ver} os=#{os} arch=#{arch}")
IO.puts("P1f offset=#{offset} len=#{len}")
IO.puts("P1f arithmetic: offset+len+56=#{offset + len + 56} == size #{offset + len + 56 == n}")
IO.puts("P1f launcher_bytes=#{byte_size(launcher)} payload_bytes=#{byte_size(payload)}")
IO.puts("P1f sha256(payload) matches trailer: #{digest == sha}")
IO.puts("P1f sha256 hex=#{Base.encode16(digest, case: :lower)}")

# Gzip magic of the payload slice: a drop is launcher ++ GZIP.
IO.puts("P1f payload gzip magic: #{inspect(binary_part(payload, 0, 2))}")

# A gzip + tar round-trip sanity check on the same code path `bl pack` will use.
gzipped = :zlib.gzip(binary_part(payload, 0, 4096))
IO.puts("P1f zlib.gzip of a 4 KiB slice -> #{byte_size(gzipped)} bytes (deterministic re-gzip: #{:zlib.gzip(binary_part(payload, 0, 4096)) == gzipped})")

if other = System.get_env("BL_SELF") do
  od = File.read!(other)
  on = byte_size(od)
  <<ooff::little-64, olen::little-64, _::binary-32, _::8, _::8, _::little-16, om::binary-4>> =
    binary_part(od, on - 56, 56)

  IO.puts("P1f other=#{other} magic=#{om} offset=#{ooff} len=#{olen} consistent=#{ooff + olen + 56 == on}")
end
