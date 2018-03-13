module ::Sushi::Core
  # SushiChain Address Resolution System
  # todo:
  # record rejected transactions
  # integrated into e2e

  # valid suffixes
  SUFFIX = %w(sc)

  class Scars < DApp
    @domains_internal : Array(DomainMap) = Array(DomainMap).new

    def sales : Array(Models::Domain)
      # todo
    end

    def get(domain_name : String) : Models::Domain?
      return nil if @domains_internal.size < CONFIRMATION
      get_for(domain_name, @domains_internal.reverse[(CONFIRMATION - 1)..-1])
    end

    def get_unconfirmed(domain_name, transactions : Array(Transaction)) : Models::Domain?
      domain_map = create_domain_map_for_transactions(transactions)

      tmp_domains_internal = @domains_internal.dup
      tmp_domains_internal.push(domain_map)

      get_for(domain_name, tmp_domains_internal.reverse)
    end

    def actions : Array(String)
      ["scars_buy", "scars_sell"]
    end

    def related?(action : String) : Bool
      action.starts_with?("scars_")
    end

    def valid_impl?(transaction : Transaction, prev_transactions : Array(Transaction)) : Bool
      case transaction.action
      when "scars_buy"
        return valid_buy?(transaction, prev_transactions)
      when "scars_sell"
        return valid_sell?(transaction, prev_transactions)
      end

      false
    end

    def valid_buy?(transaction : Transaction, transactions : Array(Transaction)) : Bool
      sender = transaction.senders[0]
      recipients = transaction.recipients
      domain_name = transaction.message
      address = sender[:address]
      price = sender[:amount]

      valid_domain?(domain_name)

      sale_price = if domain = get_unconfirmed(domain_name, transactions)
                     raise "domain #{domain_name} is not for sale now" unless domain[:status] == Models::DomainStatus::ForSale
                     raise "you have to the set a domain owener as a recipient" if recipients.size == 0
                     raise "you cannot set multiple recipients" if recipients.size > 1

                     recipient_address = recipients[0][:address]

                     raise "domain address mismatch: #{recipient_address} vs #{domain[:address]}" if recipient_address != domain[:address]

                     domain[:price]
                   else
                     raise "you cannot set a recipient since no body has bought the domain: #{domain_name}" if recipients.size > 0
                     0 # default price
                   end

      raise "the price #{price} is different of #{sale_price}" unless sale_price == price

      true
    end

    def valid_sell?(transaction : Transaction, transactions : Array(Transaction)) : Bool
      raise "you have to set one recipient" if transaction.recipients.size != 1

      sender = transaction.senders[0]
      domain_name = transaction.message
      address = sender[:address]
      price = sender[:amount]

      recipient = transaction.recipients[0]

      raise "address mistach for scars_sell: #{address} vs #{recipient[:address]}" if address != recipient[:address]
      raise "price mistach for scars_sell: #{price} vs #{recipient[:amount]}" if price != recipient[:amount]
      raise "domain #{domain_name} not found" unless domain = get_unconfirmed(domain_name, transactions)
      raise "domain address mismatch: #{address} vs #{domain[:address]}" unless address == domain[:address]
      raise "the price have to be greater than 0" if price < 0

      true
    end

    def valid_domain?(domain_name : String) : Bool
      raise "domain have to be shorter than 20 characters" if domain_name.size > 20
      raise "domain have to contains at least one dot" unless domain_name.includes?(".")

      domain_parts = domain_name.split(".")

      raise "domain cannot contain an empty part between dots" if domain_parts.includes?("")
      raise "domain have to be ended with #{SUFFIX} (#{domain_parts[-1]})" unless SUFFIX.includes?(domain_parts[-1])

      true
    end

    def self.valid_domain?(domain_name : String) : Bool
      self.new.valid_domain?(domain_name)
    end

    def record(chain)
      chain[@domains_internal.size..-1].each do |block|
        domain_map = create_domain_map_for_transactions(block.transactions)
        @domains_internal.push(domain_map)
      end
    end

    def clear
      @domains_internal.clear
    end

    private def get_for(domain_name : String, domains : Array(DomainMap)) : Models::Domain?
      p domains
      domains.each do |domains_internal|
        return domains_internal[domain_name] if domains_internal[domain_name]?
      end

      nil
    end

    private def create_domain_map_for_transactions(transactions : Array(Transaction)) : DomainMap
      domain_map = DomainMap.new

      transactions.each do |transaction|
        next if transaction.action != "scars_buy" && transaction.action != "scars_sell"

        domain_name = transaction.message
        address = transaction.senders[0][:address]
        price = transaction.senders[0][:amount]

        case transaction.action
        when "scars_buy"
          domain_map[domain_name] = {
            domain_name: domain_name,
            address:     address,
            price:       price,
            status:      Models::DomainStatus::Acquired,
          }
        when "scars_sell"
          domain_map[domain_name] = {
            domain_name: domain_name,
            address:     address,
            price:       price,
            status:      Models::DomainStatus::ForSale,
          }
        end
      end

      domain_map
    end

    def fee(action : String) : Int64
      case action
      when "scars_buy"
        return 100_i64
      when "scars_sell"
        return 10_i64
      end

      0_i64 # not coming here
    end

    include Consensus
  end
end
