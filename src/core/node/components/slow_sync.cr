# Copyright © 2017-2020 The Axentro Core developers
#
# See the LICENSE file at the top-level directory of this distribution
# for licensing information.
#
# Unless otherwise agreed in a custom licensing agreement with the Axentro Core developers,
# no part of this software, including this file, may be copied, modified,
# propagated, or distributed except according to the terms contained in the
# LICENSE file.
#
# Removal or modification of this copyright notice is prohibited.

module ::Axentro::Core::NodeComponents

    enum SlowSyncState
      CREATE
      REPLACE
      REBROADCAST
      SYNC_LOCAL
      SYNC_PEER
    end

    class SlowSync

      def initialize(@incoming_block : SlowBlock, @mining_block : SlowBlock, @database : Database, @latest_slow : SlowBlock) ; end
      
      def process
        has_block = @database.get_block(@incoming_block.index)
        
        if has_block
          already_in_db(has_block.not_nil!.as(SlowBlock))
        else
          not_in_db
        end
      end

      private def not_in_db
        # if incoming block next in sequence
        if @incoming_block.index == @latest_slow.index + 2
          SlowSyncState::CREATE
        else
          # if incoming block not next in sequence
          if @incoming_block.index > @latest_slow.index + 2
            # incoming is ahead of next in sequence
            SlowSyncState::SYNC_LOCAL
          else
            # incoming is behind next in sequence 
            SlowSyncState::SYNC_PEER
          end
        end    
      end

      private def already_in_db(existing_block : SlowBlock)
        # if incoming block latest in sequence
        if @incoming_block.index == @latest_slow.index
            if @incoming_block.timestamp < existing_block.timestamp
              # incoming block is earlier then ours (take theirs)
              SlowSyncState::REPLACE
            elsif @incoming_block.timestamp > existing_block.timestamp
              # incoming block is not as early as ours (keep ours & re-broadcast it)
              SlowSyncState::REBROADCAST
            else
              # incoming block is exactly the same timestamp - what to do here?
            end
        else
          # if incoming block is not latest in sequence 
          if @incoming_block.index > @latest_slow.index
            # incoming block is ahead of our latest
            SlowSyncState::SYNC_LOCAL
          else
            # incoming block is behind our latest
            SlowSyncState::SYNC_PEER
          end   
        end
      end
      
    end

end