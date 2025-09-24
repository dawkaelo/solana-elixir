defmodule Solana.VersionedTransaction do
  @moduledoc """
  VersionedTransaction implementation for Solana v0 transactions.

  This matches the format used in Solana web3.js VersionedTransaction class.
  """

  alias Solana.{VersionedMessage, ShortVec}

  @signature_length 64

  @type t :: %__MODULE__{
    signatures: [binary()],
    message: VersionedMessage.t()
  }

  defstruct [:signatures, :message]

  @doc """
  Create a new VersionedTransaction.
  """
  def new(message, signatures \\ nil) do
    signatures = signatures || create_empty_signatures(message.header.num_required_signatures)

    %__MODULE__{
      signatures: signatures,
      message: message
    }
  end

  @doc """
  Create a VersionedTransaction from instructions and parameters.
  """
  def from_instructions(instructions, payer_key, recent_blockhash, opts \\ []) do
    message = VersionedMessage.new(instructions, payer_key, recent_blockhash, opts)
    new(message)
  end

  @doc """
  Serialize the VersionedTransaction to binary format.

  This matches the web3.js VersionedTransaction.serialize() method:
  - encodedSignaturesLength (shortvec encoded)
  - signatures (64 bytes each)
  - serializedMessage
  """
  def serialize(%__MODULE__{} = transaction) do
    # Serialize the message
    serialized_message = VersionedMessage.serialize(transaction.message)

    # Encode signatures length using shortvec
    signatures_length_encoded = ShortVec.encode_length(length(transaction.signatures))

    # Signatures (64 bytes each)
    signatures_bytes = transaction.signatures
                      |> Enum.reduce(<<>>, fn signature, acc ->
                        acc <> ensure_signature_length(signature)
                      end)

    # Combine: signatures_length + signatures + message
    signatures_length_encoded <> signatures_bytes <> serialized_message
  end

  @doc """
  Sign the transaction with the provided keypairs.

  keypairs should be a list of {secret_key, public_key} tuples.
  """
  def sign(%__MODULE__{} = transaction, keypairs) when is_list(keypairs) do
    message_data = VersionedMessage.serialize(transaction.message)

    # Get the public keys that need to sign
    signer_pubkeys = Enum.take(transaction.message.static_account_keys,
                              transaction.message.header.num_required_signatures)

    # Sign with each keypair
    new_signatures = for {secret_key, public_key} <- keypairs do
      signer_index = Enum.find_index(signer_pubkeys, fn pubkey ->
        pubkey == public_key
      end)

      if signer_index do
        # Sign the message data
        :crypto.sign(:eddsa, :sha512, message_data, [secret_key, :ed25519])
      else
        # Keep existing signature or create empty one
        Enum.at(transaction.signatures, signer_index) || create_empty_signature()
      end
    end

    # Update signatures, keeping existing ones for non-provided keypairs
    updated_signatures = transaction.signatures
                        |> Enum.with_index()
                        |> Enum.map(fn {existing_sig, index} ->
                          Enum.at(new_signatures, index) || existing_sig
                        end)

    %{transaction | signatures: updated_signatures}
  end

  @doc """
  Add a signature for a specific public key.
  """
  def add_signature(%__MODULE__{} = transaction, public_key, signature) do
    signer_pubkeys = Enum.take(transaction.message.static_account_keys,
                              transaction.message.header.num_required_signatures)

    signer_index = Enum.find_index(signer_pubkeys, fn pubkey ->
      pubkey == public_key
    end)

    if signer_index do
      new_signatures = List.replace_at(transaction.signatures, signer_index,
                                      ensure_signature_length(signature))
      %{transaction | signatures: new_signatures}
    else
      raise ArgumentError, "Public key #{inspect(public_key)} is not required to sign this transaction"
    end
  end

  @doc """
  Get the transaction version.
  """
  def version(%__MODULE__{message: message}), do: message.version

  # Private functions

  defp create_empty_signatures(count) do
    for _ <- 1..count, do: create_empty_signature()
  end

  defp create_empty_signature do
    :binary.copy(<<0>>, @signature_length)
  end

  defp ensure_signature_length(signature) when byte_size(signature) == @signature_length do
    signature
  end

  defp ensure_signature_length(signature) when byte_size(signature) < @signature_length do
    padding_size = @signature_length - byte_size(signature)
    signature <> :binary.copy(<<0>>, padding_size)
  end

  defp ensure_signature_length(signature) when byte_size(signature) > @signature_length do
    binary_part(signature, 0, @signature_length)
  end
end