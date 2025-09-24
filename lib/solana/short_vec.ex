defmodule Solana.ShortVec do
  @moduledoc """
  ShortVec encoding utilities for compact length encoding.

  This is used in Solana's VersionedTransaction format to encode
  the length of arrays in a compact binary format.
  """

  @doc """
  Encode a length value using short vector encoding.

  This matches the shortvec encoding used in Solana web3.js:
  - Values 0-127: single byte
  - Values 128-16383: two bytes with continuation bit
  - And so on...
  """
  def encode_length(length) when is_integer(length) and length >= 0 do
    do_encode_length(length, [])
  end

  defp do_encode_length(length, acc) when length < 128 do
    Enum.reverse([length | acc]) |> :binary.list_to_bin()
  end

  defp do_encode_length(length, acc) do
    byte = rem(length, 128) + 128  # Set continuation bit
    do_encode_length(div(length, 128), [byte | acc])
  end

  @doc """
  Decode a length value from short vector encoding.

  Returns {decoded_length, remaining_bytes}.
  """
  def decode_length(<<>>), do: {0, <<>>}

  def decode_length(<<byte, rest::binary>>) when byte < 128 do
    {byte, rest}
  end

  def decode_length(data) when is_binary(data) do
    do_decode_length(data, 0, 0)
  end

  defp do_decode_length(<<byte, rest::binary>>, acc, shift) when byte >= 128 do
    new_acc = acc + ((byte - 128) <<< shift)
    do_decode_length(rest, new_acc, shift + 7)
  end

  defp do_decode_length(<<byte, rest::binary>>, acc, shift) do
    final_length = acc + (byte <<< shift)
    {final_length, rest}
  end

  defp do_decode_length(<<>>, acc, _shift) do
    {acc, <<>>}
  end
end