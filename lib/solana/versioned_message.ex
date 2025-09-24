defmodule Solana.VersionedMessage do
  @moduledoc """
  VersionedMessage for Solana v0 transactions.

  This supports both legacy messages and v0 messages with Address Lookup Tables.
  """

  alias Solana.{Instruction, ShortVec}

  @type version :: :legacy | 0

  @type t :: %__MODULE__{
    version: version(),
    header: %{
      num_required_signatures: non_neg_integer(),
      num_readonly_signed_accounts: non_neg_integer(),
      num_readonly_unsigned_accounts: non_neg_integer()
    },
    static_account_keys: [binary()],
    recent_blockhash: binary(),
    instructions: [Instruction.t()],
    address_table_lookups: [map()]
  }

  defstruct [
    :version,
    :header,
    :static_account_keys,
    :recent_blockhash,
    :instructions,
    :address_table_lookups
  ]

  @doc """
  Create a new VersionedMessage from instructions and other parameters.
  """
  def new(instructions, payer_key, recent_blockhash, opts \\ []) do
    version = Keyword.get(opts, :version, 0)
    address_table_lookups = Keyword.get(opts, :address_table_lookups, [])

    # Collect all unique account keys
    all_accounts = collect_accounts(instructions, payer_key)

    # Build header
    header = %{
      num_required_signatures: count_signers(instructions, all_accounts),
      num_readonly_signed_accounts: 0,  # Simplified for now
      num_readonly_unsigned_accounts: count_readonly_accounts(instructions, all_accounts)
    }

    %__MODULE__{
      version: version,
      header: header,
      static_account_keys: all_accounts,
      recent_blockhash: recent_blockhash,
      instructions: instructions,
      address_table_lookups: address_table_lookups
    }
  end

  @doc """
  Serialize the VersionedMessage to binary format.
  """
  def serialize(%__MODULE__{} = message) do
    # Start with version byte (0 for v0 transactions)
    version_byte = case message.version do
      :legacy -> <<>>  # Legacy transactions don't have version byte
      0 -> <<0>>
      _ -> <<message.version>>
    end

    # Header (3 bytes)
    header_bytes = <<
      message.header.num_required_signatures,
      message.header.num_readonly_signed_accounts,
      message.header.num_readonly_unsigned_accounts
    >>

    # Account keys
    accounts_count = ShortVec.encode_length(length(message.static_account_keys))
    accounts_bytes = Enum.reduce(message.static_account_keys, <<>>, fn key, acc ->
      acc <> ensure_32_bytes(key)
    end)

    # Recent blockhash (32 bytes)
    blockhash_bytes = ensure_32_bytes(message.recent_blockhash)

    # Instructions
    instructions_bytes = serialize_instructions(message.instructions, message.static_account_keys)

    # Address table lookups (for v0 transactions)
    lookups_bytes = case message.version do
      0 -> serialize_address_table_lookups(message.address_table_lookups)
      _ -> <<>>
    end

    # Combine all parts
    version_byte <> header_bytes <> accounts_count <> accounts_bytes <>
    blockhash_bytes <> instructions_bytes <> lookups_bytes
  end

  defp collect_accounts(instructions, payer_key) do
    # Start with payer as first account
    instruction_accounts = instructions
                          |> Enum.flat_map(fn instruction ->
                            get_instruction_accounts(instruction)
                          end)
                          |> Enum.uniq()

    # Ensure payer is first
    [payer_key | instruction_accounts -- [payer_key]] |> Enum.uniq()
  end

  defp get_instruction_accounts(%Instruction{accounts: accounts}) do
    accounts
    |> Enum.map(fn account -> account.key end)
  end

  defp count_signers(instructions, all_accounts) do
    # Count unique accounts that need to sign
    signing_accounts = instructions
                      |> Enum.flat_map(fn instruction ->
                        instruction.accounts
                        |> Enum.filter(fn account -> account.signer? end)
                        |> Enum.map(fn account -> account.key end)
                      end)
                      |> Enum.uniq()

    length(signing_accounts)
  end

  defp count_readonly_accounts(instructions, all_accounts) do
    # Count accounts that are not writable in any instruction
    writable_accounts = instructions
                       |> Enum.flat_map(fn instruction ->
                         instruction.accounts
                         |> Enum.filter(fn account -> account.writable? end)
                         |> Enum.map(fn account -> account.key end)
                       end)
                       |> Enum.uniq()

    length(all_accounts) - length(writable_accounts) - 1  # -1 for payer who is always writable
  end

  defp serialize_instructions(instructions, account_keys) do
    instructions_count = ShortVec.encode_length(length(instructions))

    instructions_data = instructions
                       |> Enum.reduce(<<>>, fn instruction, acc ->
                         acc <> serialize_instruction(instruction, account_keys)
                       end)

    instructions_count <> instructions_data
  end

  defp serialize_instruction(%Instruction{} = instruction, account_keys) do
    # Find program ID index
    program_index = Enum.find_index(account_keys, fn key -> key == instruction.program end)
    program_index = program_index || 0

    # Account indices
    account_indices = instruction.accounts
                     |> Enum.map(fn account ->
                       Enum.find_index(account_keys, fn key -> key == account.key end) || 0
                     end)

    accounts_count = ShortVec.encode_length(length(account_indices))
    accounts_bytes = Enum.reduce(account_indices, <<>>, fn index, acc ->
      acc <> <<index>>
    end)

    # Instruction data
    data_length = ShortVec.encode_length(byte_size(instruction.data))

    <<program_index>> <> accounts_count <> accounts_bytes <> data_length <> instruction.data
  end

  defp serialize_address_table_lookups(lookups) do
    lookups_count = ShortVec.encode_length(length(lookups))

    lookups_data = lookups
                  |> Enum.reduce(<<>>, fn lookup, acc ->
                    # Each lookup has: account_key + writable_indices + readonly_indices
                    account_key = ensure_32_bytes(lookup[:account_key] || <<0::256>>)

                    writable_indices = lookup[:writable_indices] || []
                    readonly_indices = lookup[:readonly_indices] || []

                    writable_count = ShortVec.encode_length(length(writable_indices))
                    writable_bytes = Enum.reduce(writable_indices, <<>>, fn idx, acc_inner ->
                      acc_inner <> <<idx>>
                    end)

                    readonly_count = ShortVec.encode_length(length(readonly_indices))
                    readonly_bytes = Enum.reduce(readonly_indices, <<>>, fn idx, acc_inner ->
                      acc_inner <> <<idx>>
                    end)

                    acc <> account_key <> writable_count <> writable_bytes <> readonly_count <> readonly_bytes
                  end)

    lookups_count <> lookups_data
  end

  defp ensure_32_bytes(data) when is_binary(data) and byte_size(data) == 32, do: data
  defp ensure_32_bytes(data) when is_binary(data) and byte_size(data) < 32 do
    padding_size = 32 - byte_size(data)
    data <> :binary.copy(<<0>>, padding_size)
  end
  defp ensure_32_bytes(data) when is_binary(data) and byte_size(data) > 32 do
    binary_part(data, 0, 32)
  end
  defp ensure_32_bytes(data) when is_binary(data), do: data
end