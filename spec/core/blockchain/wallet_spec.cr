
require "./../../spec_helper"

include Sushi::Core

describe Wallet do

  describe "create new wallet" do

    it "should create a new wallet on the testnet" do
      wallet = Wallet.from_json(Wallet.create(true).to_json)
      Wallet.verify!(wallet.secret_key,wallet.public_key_x, wallet.public_key_y, wallet.address).should be_true
      Wallet.address_network_type(wallet.address).should eq({prefix: "T0", name: "testnet"})
    end

    it "should create a new wallet on the mainnet" do
      wallet = Wallet.from_json(Wallet.create(false).to_json)
      Wallet.verify!(wallet.secret_key,wallet.public_key_x, wallet.public_key_y, wallet.address).should be_true
      Wallet.address_network_type(wallet.address).should eq({prefix: "M0", name: "mainnet"})
    end

  end

  describe "verify wallet" do

    it "should verify a valid wallet" do
      wallet = Wallet.from_json(Wallet.create(true).to_json)
      Wallet.verify!(wallet.secret_key,wallet.public_key_x, wallet.public_key_y, wallet.address).should be_true
    end

    it "should raise an invalid checksum error when address is invalid" do
       expect_raises(Exception, "Invalid checksum for invalid-wallet-address") do
         wallet = Wallet.from_json(Wallet.create(true).to_json)
         Wallet.verify!(wallet.secret_key,wallet.public_key_x, wallet.public_key_y, "invalid-wallet-address")
       end
    end

    it "should raise an invalid public key error when public_key_raw_x does not match public_key_x" do
       wallet1 = Wallet.from_json(Wallet.create(true).to_json)
       wallet2 = Wallet.from_json(Wallet.create(true).to_json)

       expected_keys = create_expected_keys(wallet1.public_key_x, wallet1.public_key_y, wallet2.secret_key)
       public_key_raw_x = expected_keys[:public_key_raw_x]
       public_key_x = expected_keys[:public_key_x]

       expect_raises(Exception, "Invalid public key (public_key_x) for #{public_key_raw_x} != #{public_key_x}") do
         Wallet.verify!(wallet2.secret_key,wallet1.public_key_x, wallet1.public_key_y, wallet1.address).should be_true
       end
    end

    it "should raise an invalid public key error when public_key_raw_y does not match public_key_y" do
       wallet1 = Wallet.from_json(Wallet.create(true).to_json)
       wallet2 = Wallet.from_json(Wallet.create(true).to_json)

       expected_keys = create_expected_keys(wallet1.public_key_x, wallet2.public_key_y, wallet1.secret_key)
       public_key_raw_y = expected_keys[:public_key_raw_y]
       public_key_y = expected_keys[:public_key_y]

       expect_raises(Exception, "Invalid public key (public_key_y) for #{public_key_raw_y} != #{public_key_y}") do
         Wallet.verify!(wallet1.secret_key,wallet1.public_key_x, wallet2.public_key_y, wallet1.address)
       end
    end

  end

  describe "#valid_checksum?" do

    it "should return true when valid checksum" do
      wallet = Wallet.from_json(Wallet.create(true).to_json)
      Wallet.valid_checksum?(wallet.address).should be_true
    end

    it "should return false when invalid checksum" do
      Wallet.valid_checksum?("invalid-wallet-address").should be_false
    end

  end

  describe "#address_network_type?" do

    it "should return testnet with a valid testnet address" do
      wallet = Wallet.from_json(Wallet.create(true).to_json)
      Wallet.address_network_type(wallet.address).should eq({prefix: "T0", name: "testnet"})
    end

    it "should return mainnet with a valid mainnet address" do
      wallet = Wallet.from_json(Wallet.create(false).to_json)
      Wallet.address_network_type(wallet.address).should eq({prefix: "M0", name: "mainnet"})
    end

    it "should raise an invalid checksum error when address is invalid" do
      expect_raises(Exception, "Invalid checksum for the address: invalid-wallet-address") do
        Wallet.address_network_type("invalid-wallet-address")
      end
    end

  end

end

def create_expected_keys(key_x, key_y, secret_key)
  secp256k1 = ECDSA::Secp256k1.new
  public_key_raw_x = BigInt.new(Base64.decode_string(key_x), base: 10)
  public_key_raw_y = BigInt.new(Base64.decode_string(key_y), base: 10)

  secret_key_raw = BigInt.new(Base64.decode_string(secret_key), base: 10)
  public_key = secp256k1.create_key_pair(secret_key_raw)[:public_key]
  public_key_x = public_key.x.to_s(base: 10)
  public_key_y = public_key.y.to_s(base: 10)
  {public_key_raw_x: public_key_raw_x, public_key_x: public_key_x, public_key_raw_y: public_key_raw_y, public_key_y: public_key_y}
end
