require 'ruboty/message'

module Ruboty
  module SlackRTM
    module Message
      def add_reaction(reaction)
        channel_id = @original[:from]
        timestamp  = sprintf("%.6f", @original[:time].to_f)
        robot.add_reaction(reaction, channel_id, timestamp)
      end
    end
  end

  Message.include SlackRTM::Message
end
