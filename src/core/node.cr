require "./node/*"

module ::Sushi::Core
  class Node
    property flag : Int32

    getter network_type : String
    getter latest_unknown : Int64? = nil

    @blockchain : Blockchain
    @miners_manager : MinersManager
    @chord : Chord

    @rpc_controller : Controllers::RPCController

    @cc : Int32 = 0
    @c0 : Int32 = 0
    @c1 : Int32 = 0
    @c2 : Int32 = 0
    @c3 : Int32 = 0

    def initialize(
      @is_private : Bool,
      @is_testnet : Bool,
      @bind_host : String,
      @bind_port : Int32,
      @public_host : String?,
      @public_port : Int32?,
      @ssl : Bool?,
      @connect_host : String?,
      @connect_port : Int32?,
      @wallet : Wallet,
      @database : Database?,
      @conn_min : Int32,
      @use_ssl : Bool = false
    )
      @blockchain = Blockchain.new(@wallet, @database)
      @network_type = @is_testnet ? "testnet" : "mainnet"
      @chord = Chord.new(@public_host, @public_port, @ssl, @network_type, @is_private, @use_ssl)
      @miners_manager = MinersManager.new
      @flag = FLAG_NONE

      info "core version: #{light_green(Core::CORE_VERSION)}"

      debug "is_private: #{light_green(@is_private)}"
      debug "public url: #{light_green(@public_host)}:#{light_green(@public_port)}" unless @is_private
      debug "connecting node is using ssl?: #{light_green(@use_ssl)}"
      debug "network type: #{light_green(@network_type)}"

      @rpc_controller = Controllers::RPCController.new(@blockchain)

      wallet_network = Wallet.address_network_type(@wallet.address)

      unless wallet_network[:name] == @network_type
        error "wallet type mismatch"
        error "node's   network: #{@network_type}"
        error "wallet's network: #{wallet_network[:name]}"
        exit -1
      end

      spawn proceed_setup2
    end

    def run!
      @rpc_controller.set_node(self)

      draw_routes!

      info "start running Sushi's node on #{light_green(@bind_host)}:#{light_green(@bind_port)}"

      node = HTTP::Server.new(@bind_host, @bind_port, handlers)
      node.listen
    end

    private def draw_routes!
      options "/rpc" do |context|
        context.response.headers["Allow"] = "HEAD,GET,PUT,POST,DELETE,OPTIONS"
        context.response.headers["Access-Control-Allow-Origin"] = "*"
        context.response.headers["Access-Control-Allow-Headers"] =
          "X-Requested-With, X-HTTP-Method-Override, Content-Type, Cache-Control, Accept"

        context.response.status_code = 200
        context.response.print ""
        context
      end

      post "/rpc" do |context, params|
        context.response.headers["Access-Control-Allow-Origin"] = "*"
        @rpc_controller.exec(context, params)
      end
    end

    private def sync_chain
      info "start synching blockchain."

      if successor = @chord.find_successor?
        send(
          successor[:socket],
          M_TYPE_NODE_REQUEST_CHAIN,
          {
            latest_index: @latest_unknown ? @latest_unknown.not_nil! - 1 : 0,
          }
        )
      else
        warning "successor not found. skip synching blockchain."

        if @flag == FLAG_BLOCKCHAIN_SYNCING
          @flag = FLAG_SETUP_PRE_DONE
          proceed_setup2
        end
      end
    end

    private def peer_handler : WebSocketHandler
      WebSocketHandler.new("/peer") { |socket, context| peer(socket) }
    end

    def peer(socket : HTTP::WebSocket)
      socket.on_message do |message|
        message_json = JSON.parse(message)
        message_type = message_json["type"].as_i
        message_content = message_json["content"].to_s

        case message_type
        when M_TYPE_MINER_HANDSHAKE
          @miners_manager.handshake(self, @blockchain, socket, message_content)
        when M_TYPE_MINER_FOUND_NONCE
          @miners_manager.found_nonce(self, @blockchain, socket, message_content)
        when M_TYPE_CHORD_JOIN
          @chord.join(self, message_content)
        when M_TYPE_CHORD_SEARCH_SUCCESSOR
          @chord.search_successor(self, message_content)
        when M_TYPE_CHORD_FOUND_SUCCESSOR
          @chord.found_successor(self, message_content)
        when M_TYPE_CHORD_STABILIZE_AS_SUCCESSOR
          @chord.stabilize_as_successor(self, socket, message_content)
        when M_TYPE_CHORD_STABILIZE_AS_PREDECESSOR
          @chord.stabilize_as_predecessor(self, socket, message_content)
        when M_TYPE_NODE_REQUEST_CHAIN
          _request_chain(socket, message_content)
        when M_TYPE_NODE_RECIEVE_CHAIN
          _recieve_chain(socket, message_content)
        when M_TYPE_NODE_BROADCAST_TRANSACTION
          _broadcast_transaction(socket, message_content)
        when M_TYPE_NODE_BROADCAST_BLOCK
          _broadcast_block(socket, message_content)
        end
      rescue e : Exception
        handle_exception(socket, e)
      end

      socket.on_close do |_|
        reject!(socket, nil)
      end
    rescue e : Exception
      handle_exception(socket, e)
    end

    def broadcast_transaction(transaction : Transaction, from : NodeContext? = nil)
      info "new transaction coming: #{transaction.id}"

      @blockchain.add_transaction(transaction)

      if successor = @chord.find_successor?
        if !from.nil? && from.not_nil![:id] == successor[:context][:id]
          debug "successfully broadcasted transaction!"
          return
        end

        send(
          successor[:socket],
          M_TYPE_NODE_BROADCAST_TRANSACTION,
          {
            transaction: transaction,
            from:        from || @chord.context,
          }
        )
      end
    end

    def send_block(block : Block, from : NodeContext? = nil)
      if successor = @chord.find_successor?
        debug "send block (#{block.index}) to #{successor[:context][:host]}:#{successor[:context][:port]}"
        send(
          successor[:socket],
          M_TYPE_NODE_BROADCAST_BLOCK,
          {
            block: block,
            from:  from || @chord.context,
          }
        )
      else
        warning "successor not found. skip sending a block"
      end
    end

    def broadcast_block(block : Block, from : NodeContext? = nil)
      @cc += 1

      if @blockchain.latest_index + 1 == block.index
        @c0 += 1

        return analytics unless @blockchain.push_block?(block)

        info "new block coming: #{light_cyan(@blockchain.chain.size)}"

        if successor = @chord.find_successor?
          if !from.nil? && from.not_nil![:id] != successor[:context][:id]
            send_block(block, from)
          end
        end
      elsif @blockchain.latest_index == block.index
        @c1 += 1

        warning "blockchain conflicted"
        warning "ignore the block. (#{light_cyan(@blockchain.chain.size)})"

        @latest_unknown ||= block.index
      elsif @blockchain.latest_index + 1 < block.index
        @c2 += 1

        warning "required new chain: #{@blockchain.latest_block.index} for #{block.index}"

        sync_chain
      else
        @c3 += 1

        warning "recieved old block, will be ignored"
      end

      analytics
    end

    private def handle_exception(socket : HTTP::WebSocket, e : Exception, reject_node : Bool = false)
      if error_message = e.message
        error error_message
      else
        error "unknown error"
      end

      reject!(socket, e)

      error e.backtrace.not_nil!.join("\n")
    end

    private def analytics
      info "recieved block >> total: #{light_cyan(@cc)}, new block: #{light_cyan(@c0)}, " +
           "conflict: #{light_cyan(@c1)}, sync chain: #{light_cyan(@c2)}, older block: #{light_cyan(@c3)}"
    end

    private def _broadcast_transaction(socket, _content)
      return unless @flag == FLAG_SETUP_DONE

      _m_content = M_CONTENT_NODE_BROADCAST_TRANSACTION.from_json(_content)

      transaction = _m_content.transaction
      from = _m_content.from

      broadcast_transaction(transaction, from)
    end

    private def _broadcast_block(socket, _content)
      return unless @flag == FLAG_SETUP_DONE

      _m_content = M_CONTENT_NODE_BROADCAST_BLOCK.from_json(_content)

      block = _m_content.block
      from = _m_content.from

      broadcast_block(block, from)
    end

    private def _request_chain(socket, _content)
      _m_content = M_CONTENT_NODE_REQUEST_CHAIN.from_json(_content)

      latest_index = _m_content.latest_index

      info "requested new chain: #{latest_index}"

      send(socket, M_TYPE_NODE_RECIEVE_CHAIN, {chain: @blockchain.subchain(latest_index + 1)})
    end

    private def _recieve_chain(socket, _content)
      _m_content = M_CONTENT_NODE_RECIEVE_CHAIN.from_json(_content)

      chain = _m_content.chain

      if _chain = chain
        info "recieved chain's size: #{_chain.size}"
      else
        info "recieved empty chain."
      end

      current_latest_index = @blockchain.latest_index

      if @blockchain.replace_chain(chain)
        info "chain updated: #{light_green(current_latest_index)} -> #{light_green(@blockchain.latest_index)}"
        @miners_manager.broadcast_latest_block(@blockchain)
      end

      if @flag == FLAG_BLOCKCHAIN_SYNCING
        @flag = FLAG_SETUP_PRE_DONE
        proceed_setup2
      end
    end

    private def reject!(socket : HTTP::WebSocket, _e : Exception?)
      @chord.clean_connection(socket)
      @miners_manager.clean_connection(socket)

      if e = _e
        if error_message = e.message
          error error_message
        end
      end
    end

    private def handlers
      [
        peer_handler,
        route_handler,
      ]
    end

    def proceed_setup2
      return if @flag == FLAG_SETUP_DONE

      case @flag
      when FLAG_NONE
        if @connect_host && @connect_port
          @flag = FLAG_CONNECTING_NODES

          @chord.join_to(@connect_host.not_nil!, @connect_port.not_nil!)
        else
          warning "no connecting node has been specified"
          warning "so this node is standalone from other network"

          @flag = FLAG_BLOCKCHAIN_LOADING

          proceed_setup2
        end
      when FLAG_BLOCKCHAIN_LOADING
        @blockchain.setup(self)

        info "loaded blockchain's size: #{light_cyan(@blockchain.chain.size)}"

        if @database
          @latest_unknown = @blockchain.latest_index + 1
        else
          warning "no database has been specified"
        end

        @flag = FLAG_BLOCKCHAIN_SYNCING

        proceed_setup2
      when FLAG_BLOCKCHAIN_SYNCING
        sync_chain
      when FLAG_SETUP_PRE_DONE
        info "successfully setup the node."

        @flag = FLAG_SETUP_DONE
      end
    end

    include Logger
    include Router
    include Protocol
    include Common::Color
    include NodeComponents
  end
end
