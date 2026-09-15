# frozen_string_literal: true

require_relative "../test_helper"
require "kioku/content_address"

# "Use Ruby's standard digest support for SHA-256 content addressing; version the hash
# algorithm in evidence handles" [plan §4.2]. The handle shape is
# {content_hash, hash_algorithm, byte_length} [contracts: context_fetch content_ref].
class KiokuContentAddressTest < Minitest::Test
  # NIST SHA-256 test vectors: the implementation must be SHA-256, not "some digest".
  EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  ABC_SHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  def address(bytes)
    Kioku::ContentAddress.for(bytes)
  end

  def test_should_produce_the_known_sha256_vector_when_the_content_is_empty
    assert_equal "sha256:#{EMPTY_SHA256}", address("").content_hash
  end

  def test_should_produce_the_known_sha256_vector_when_the_content_is_abc
    assert_equal "sha256:#{ABC_SHA256}", address("abc").content_hash
  end

  def test_should_report_sha256_as_the_hash_algorithm_so_handles_carry_their_version
    assert_equal "sha256", address("abc").hash_algorithm
  end

  # Content addressing permits byte deduplication [contracts: errors kioku.handle_unresolved].
  def test_should_produce_equal_addresses_when_two_inputs_have_identical_bytes
    first = address("the same forty-two bytes of evidence body")
    second = address("the same forty-two bytes of evidence body")

    assert_equal first.content_hash, second.content_hash
    assert_equal first, second
  end

  def test_should_produce_a_different_address_when_a_single_byte_differs
    refute_equal address("evidence body").content_hash, address("evidence bodY").content_hash
  end

  def test_should_report_the_byte_length_rather_than_the_character_length
    assert_equal 2, address("é").byte_length
  end

  # Source bytes are hashed, never text-normalized: CRLF and LF are different evidence.
  def test_should_produce_a_different_address_when_only_the_line_ending_differs
    refute_equal address("line\r\n").content_hash, address("line\n").content_hash
  end

  def test_should_produce_the_same_address_when_identical_bytes_arrive_in_different_encodings
    utf8 = "café".dup.force_encoding(Encoding::UTF_8)
    binary = utf8.dup.force_encoding(Encoding::ASCII_8BIT)

    assert_equal address(utf8).content_hash, address(binary).content_hash
  end

  def test_should_address_arbitrary_binary_content_without_raising_an_encoding_error
    binary = (0..255).map(&:chr).join.force_encoding(Encoding::ASCII_8BIT)

    assert_equal 256, address(binary).byte_length
    assert_match(/\Asha256:[0-9a-f]{64}\z/, address(binary).content_hash)
  end
end
