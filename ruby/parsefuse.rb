#!/usr/bin/env ruby

require 'stringio'
require 'parsefuse/import'

class Object

  def cvar sym
    self.class.instance_variable_get sym
  end

end

class String

  def sinsp
    inspect.gsub(/\\x00|\\0+/, '\\\\0').gsub(/\\x0/, '\x')
  end

end

class FuseMsg

  PrintLimit = 512

  class FuseMsgError < RuntimeError
  end

  Zipcodes = {
    '__s32'  => 'l',
    '__s64'  => 'q',
    '__u32'  => 'L',
    '__u64'  => 'Q',
    '__u16'  => 'S',
    'int32_t'  => 'l',
    'int64_t'  => 'q',
    'uint32_t'  => 'L',
    'uint64_t'  => 'Q',
    'uint16_t'  => 'S',
    'buf'    => 'a*',
    'string' => 'Z*'
  }


  ###### ORM layer #######
  ###### (t3h metaprogramming v00d00)

  def self.generate_bodyclass dir, op, cls = MsgBodyGeneric
    cls <= MsgBodyGeneric or raise "bodyclass is to be generated from MsgBodyGeneric"
    Class.new(cls).class_eval {
      @direction = dir
      @op = op
      extend MsgClassBaptize
      self
    }
  end

  def self.generate_bodyclasses
    Msgmap.each { |dir, ddesc|
      ddesc.each_key { |on|
        MsgBodies[[dir, on]] ||= generate_bodyclass dir, on
      }
    }
  end

  ### Controller ###
  ###### (#inspect-s belong to View, though...)

  module MsgClassBaptize

    def inspect
      "#{@op}_#{@direction}"
    end

  end

  class MsgBodyCore

    def initialize buf, msg
      @buf = buf
      @msg = msg
    end

    attr_reader :buf, :msg

    def self.inspect_buf buf, limit
      limit ||= PrintLimit
      limit < 0 && limit = buf.size
      buf.size <= limit ? buf.sinsp : buf[0...limit].sinsp + " ... [#{buf.size} bytes]"
    end

    def inspect limit = nil
      self.class.inspect_buf @buf, limit
    end

  end

  class MsgBodyGeneric < MsgBodyCore

    class Msgnode < Array

      def initialize tag = nil
        @tag = tag
      end

      def << elem, key = nil
        super [key, elem]
      end

      attr_accessor :tag
      attr_reader :buf

      def walk &b
        each { |kv|
          case kv[1]
          when Msgnode
            kv[1].walk &b
          else
            b[kv]
          end
        }
      end

      def deploy!
        walk { |kv|
          tnam = kv[1]
          case tnam
          when String
            sr = Ctypes[:Struct][tnam]
            next unless sr
          else
            sr,tnam  = tnam,nil
          end
          sm = Msgnode.new tnam
          sr.each { |typ, fld| sm.<< typ, fld }
          kv[1] = sm.deploy!
        }
        self
      end

      def [] idx
        case idx
        when Symbol
          idx = idx.to_s
          each { |k, v| k == idx and return v }
          nil
        else
          super
        end
      end

      def inspect limit = nil
        "#{@tag.to_s.sub(/^fuse_/i, "")}<%s>" % map { |k,v|
          v or next
          "#{k}#{k ? ": " : ""}%s" % case v
          when Msgnode
            v.inspect limit
          when String
            MsgBodyCore.inspect_buf v, limit
          else
            v.inspect
          end
        }.compact.join(" ")
      end

      def method_missing m, *a
        v = self[m]
        unless v
          raise NoMethodError, "undefined method `#{m}' for #{self.class}"
        end
        unless a.empty?
          raise ArgumentError, "wrong number of arguments (#{a.size} for 0)"
        end
        v
      end

      def populate! buf, dtyp
        @buf = buf
        # dtyp can be false which indicates that a special handler
        # is needed (the message description syntax is not capable of
        # properly describe the message structure). In that case
        # we just fall back to the ["buf"] description (ie. handling it
        # just as an unstructured blob).
        (dtyp || ["buf"]).each { |t| self.<< *t }
        deploy!
        leaftypes = []
        walk { |kv| leaftypes << kv[1] }
        leafvalues = buf.unpack leaftypes.map { |t| Zipcodes[t] }.join
        walk { |kv| kv[1] = leafvalues.shift }
      end

    end

    def initialize buf, msg
      super
      @tree = Msgnode.new.populate! @buf, Msgmap[cvar :@direction][cvar :@op]
    end

    attr_reader :tree

    def inspect limit = nil
      @tree.inspect limit
    end

    def method_missing *a, &b
      if @tree
        return @tree.send *a, &b
      end
      raise NoMethodError, "undefined method `#{a[0]}' for #{self.class}"
    end

  end

#  Not needed if we make use of "Z*" unpacker
#
#  MsgRenameR = generate_bodyclass 'R' , 'FUSE_RENAME'
#  MsgRenameR.class_eval {
#
#    def initialize *a
#      super
#      k, nam = @tree.pop
#      nam.split(/\0/).each { |n| @tree << n }
#    end
#
#  }

  MsgGetxattrW = generate_bodyclass 'W', 'FUSE_GETXATTR'
  MsgGetxattrW.class_eval {

    def initialize *a
      super
      if (mb = @msg.in_body) and mb[0][1][:size].zero?
        @tree = MsgBodyGeneric::Msgnode.new.populate! @buf, ["fuse_getxattr_out"]
        @treeadjusted = true
      end
    end

  }

  MsgListxattrW = generate_bodyclass 'W', 'FUSE_LISTXATTR', MsgGetxattrW
  MsgListxattrW.class_eval {

    def initialize *a
      super
      unless @treeadjusted
        @tree = MsgBodyGeneric::Msgnode.new
        @buf.split("\0").each { |nam| @tree << nam }
      end
    end

  }

  MsgReaddirW = generate_bodyclass 'W', 'FUSE_READDIR'
  MsgReaddirW.class_eval {

    const_set :Recordsig, %w[fuse_dirent]

    def self.recordsize
      @recsiz ||= const_get(:Recordsig).map {|t| FuseMsg.sizeof t }.inject(&:+)
    end

    def self.namelenext nlen
      nlen + ((8 - nlen&7) & 7)
    end

    def initialize *a
      super
      @tree = MsgBodyGeneric::Msgnode.new
      buf = @buf
      while buf.size >= self.class.recordsize
        rec = MsgBodyGeneric::Msgnode.new.populate! buf,
                self.class.const_get(:Recordsig)
        nlen = rec[-1][1].namelen
        rec << buf[self.class.recordsize..-1][0...nlen]
        @tree << rec
        buf = buf[self.class.recordsize+self.class.namelenext(nlen)..-1]
      end
    end

  }

  MsgReaddirPlusW = generate_bodyclass 'W', 'FUSE_READDIRPLUS', MsgReaddirW
  MsgReaddirPlusW.class_eval {

    const_set :Recordsig, %w[fuse_entry_out fuse_dirent]

  }

  MsgBatchForgetR = generate_bodyclass 'R', 'FUSE_BATCH_FORGET'
  MsgBatchForgetR.class_eval {

    def initialize *a
      super
      @tree = MsgBodyGeneric::Msgnode.new.populate! @buf, ["fuse_batch_forget_in"]
      # #count is a method of Enumerable therefore we have to use key retrieval
      count = @tree[0][1][:count]
      off = FuseMsg.sizeof "fuse_batch_forget_in"
      count.times {
        @tree << MsgBodyGeneric::Msgnode.new.populate!(@buf[off..-1], ["fuse_forget_one"])
        off += FuseMsg.sizeof "fuse_forget_one"
      }
    end

  }

  MsgBodies.merge! ['W', 'FUSE_GETXATTR'] => MsgGetxattrW,
                   ['W', 'FUSE_LISTXATTR'] => MsgListxattrW,
                   ['W', 'FUSE_READDIR'] => MsgReaddirW,
                   ['W', 'FUSE_READDIRPLUS'] => MsgReaddirPlusW,
                   ['R', 'FUSE_BATCH_FORGET'] => MsgBatchForgetR

  def self.sizeof tnam
    @hcac ||= {}
    @hcac[tnam] ||= MsgBodyGeneric::Msgnode.new.instance_eval {
      self << tnam
      deploy!
      leaftypes = []
      walk { |kv| leaftypes << kv[1] }
      leaftypes.map{0}.pack(leaftypes.map { |t| Zipcodes[t] }.join).size
    }
  end

  attr_accessor :in_head, :out_head, :in_body, :out_body

  module FusedumpMeta

    Size = [%w[uint32_t value]]
    FusedumpTimespec = [%w[uint32_t len], %w[uint64_t sec], %w[uint32_t nsec]]
    Buf = [%w[uint32_t len], "buf"]

  end

  class TimeBuf < Time

    attr_accessor :buf

  end

  def self.read_stream data
    data.respond_to? :read or data = StringIO.new(data)
    q = {}
    head_get = proc { |t,b|
      ts = t.to_s
      hsiz = sizeof(ts)
      h = MsgBodyGeneric::Msgnode.new(t).populate! b + data.read(hsiz - b.size), Ctypes[:Struct][ts]
      [h, hsiz]
    }
    _FORGET = %w[FUSE_FORGET FUSE_BATCH_FORGET].map {|m|
      FuseMsg::Messages.invert[m]
    }
    loop do
      dir = data.read(1) or break
      countbuf = data.read sizeof(FusedumpMeta::Size)
      count = MsgBodyGeneric::Msgnode.new.populate! countbuf, FusedumpMeta::Size
      next if count.value.zero?
      parts,hbeg = if count.value < 16
        # fusedump v2
        meta = MsgBodyGeneric::Msgnode.new
        (count.value - 1).times { |i|
          itemsizbuf = data.read(sizeof FusedumpMeta::Size)
          itemsiz = MsgBodyGeneric::Msgnode.new.populate! itemsizbuf, FusedumpMeta::Size
          databuf = itemsizbuf + data.read(itemsiz.value - itemsizbuf.size)
          meta << if i == 0 and itemsiz.value == sizeof(FusedumpMeta::FusedumpTimespec)
            # parse first item as timestamp if size is correct
            ts = MsgBodyGeneric::Msgnode.new.populate! databuf, FusedumpMeta::FusedumpTimespec
            t = TimeBuf.at(ts.sec, ts.nsec, :nsec)
            t.buf = databuf
            t
          else
            MsgBodyGeneric::Msgnode.new.populate! databuf, FusedumpMeta::Buf
          end
        }
        [[meta], ""]
      else
        # fusedump v1
        [[], countbuf]
      end
      # dir and (in case of v2 dumps) count are not included in the yielded message data,
      # so the blobs available via the #buf method of the compoments of the yielded messages
      # do not reconstruct the original binary data without gaps. This is done for presentational
      # purposes: the user visible output is generated as the pretty print of the yielded messages,
      # so we include only those parts that we want the user to see. However, the content
      # of the gaps can be reconstructed from the included parts: if the yielded message
      # data is m, then
      # - dir is avaliable as m[1].tag == :fuse_out_header ? ?W : ?R
      # - count is available as m[0].size + 1, so the original blob of count (ie. countbuf)
      #   is avaliable as [m[0].size + 1].pack(?L).
      yield parts.concat case dir
      when 'R'
        in_head, hsiz = head_get[:fuse_in_header, hbeg]
        in_head.tag = Messages[in_head.opcode] || "??"
        mbcls = MsgBodies[['R', Messages[in_head.opcode]]]
        mbcls ||= MsgBodyCore
        msg = new
        msg.in_head = in_head
        msg.in_body = mbcls.new data.read(in_head.len - hsiz), msg
        q[in_head.unique] = msg unless _FORGET.include? in_head.opcode
        [in_head, msg.in_body]
      when 'W'
        out_head, hsiz = head_get[:fuse_out_header, hbeg]
        if out_head.unique.zero?
          msg = new
          mbcls = MsgBodies[['W', Notifications[out_head.error]]]
          out_head.tag = Notifications[out_head.error] || "??"
        else
          msg = q.delete(out_head.unique) || new
          mbcls = msg.in_head ? MsgBodies[['W', Messages[msg.in_head.opcode]]] : MsgBodyCore
        end
        mbcls ||= MsgBodyCore
        msg.out_head = out_head
        msg.out_body = mbcls.new data.read(out_head.len - hsiz), msg
        [out_head, msg.out_body]
      when nil
        break
      else
        raise FuseMsgError, "bogus direction #{dir.inspect}"
      end
    end
  end

end

  ### View ###


if __FILE__ == $0
  require 'optparse'

  limit = nil
  protoh = nil
  msgy = nil
  OptionParser.new do |op|
    op.on('-l', '--limit N', Integer) { |v| limit = v }
    op.on('-p', '--proto-head F') { |v| protoh = v }
    op.on('-m', '--msgdef F') { |v| msgy = v }
  end.parse!
  FuseMsg.import_proto protoh, msgy
  FuseMsg.generate_bodyclasses
  FuseMsg.read_stream($<) { |m|
    puts m.map{|mp| mp.inspect limit}.join(" ")
  }
end

