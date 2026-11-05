# frozen_string_literal: true

require "securerandom"

# The contract every response cache store keeps (`lib/graphql/armory/caching/store.rb`), whatever holds its state.
# The including group defines:
#
# - `store`: a store whose longest accepted TTL (`max_ttl`) is 1 second, so marks may be pruned after 1 second;
# - `travel`: a callable that moves the store's clock forward by Integer milliseconds (a test clock, or a sleep).
#
# Options, for what only some stores can show:
#
# - `meta_loss: true`: the group also defines `lose_meta` (the meta record is gone: eviction, a flush, a failover to
#   a replica without it) and `rewind_seq` (takes an Integer: a failover to a replica that lost recent increments).
#   A process-local store loses its meta record only with its entries, so it has neither.
# - `prunes: true`: the store prunes purge marks once they are older than `max_ttl`. Pruning is optional; pruning
#   earlier is never allowed, and every store is held to that.
RSpec.shared_examples "a caching store" do |meta_loss: false, prunes: false|
  let(:key) { SecureRandom.hex(32) }
  let(:tag) { SecureRandom.hex(32) }
  let(:other_tag) { SecureRandom.hex(32) }

  # A miss's lookup, then the write of that run, stamped with the lookup clock as the gate stamps it.
  def store_after_lookup(store, key, blob: "blob", tags: [], ttl: 1)
    lookup = store.lookup(key)
    [lookup, store.write(key, blob, tags: tags, ttl: ttl, seq: lookup.seq, epoch: lookup.epoch, stored_at: lookup.now)]
  end

  def write_from(store, lookup, key, tags: [], ttl: 1, stored_at: lookup.now)
    store.write(key, "blob", tags: tags, ttl: ttl, seq: lookup.seq, epoch: lookup.epoch, stored_at: stored_at)
  end

  describe "the meta record" do
    it "is created by the first lookup, with seq 0 and an epoch that stays until a purge of everything" do
      first = store.lookup(key)
      second = store.lookup(SecureRandom.hex(32))

      expect([first.seq, first.epoch]).to match([0, a_string_matching(/\A\S+\z/)])
      expect(second.epoch).to eq(first.epoch)
      expect(first).to be_a(GraphQL::Armory::Caching::Lookup)
    end

    it "answers the store clock in Integer milliseconds, moving forward" do
      before = store.lookup(key).now
      travel.call(20)

      expect(store.lookup(key).now).to be_an(Integer).and(be >= before + 20)
    end
  end

  describe "#write and #lookup" do
    it "answers a stored blob with the tag digests kept beside it" do
      _lookup, written = store_after_lookup(store, key, blob: "sealed", tags: [tag, other_tag])
      found = store.lookup(key)

      expect(written).to be(true)
      expect([found.blob, found.tags.sort, found.marks]).to eq(["sealed", [tag, other_tag].sort, {}])
      expect(found).to be_found
    end

    it "answers nothing under a key nobody wrote" do
      store_after_lookup(store, key)

      expect(store.lookup(SecureRandom.hex(32))).to have_attributes(blob: nil, tags: [], marks: {})
    end

    it "lets the last valid write under a key win" do
      store_after_lookup(store, key, blob: "first", tags: [tag])
      store_after_lookup(store, key, blob: "second", tags: [other_tag])

      expect(store.lookup(key)).to have_attributes(blob: "second", tags: [other_tag])
    end

    it "never answers an expired entry" do
      lookup = store.lookup(key)
      expect(write_from(store, lookup, key, stored_at: lookup.now - 900)).to be(true)
      travel.call(150)

      expect(store.lookup(key)).not_to be_found
    end

    it "refuses an entry already expired at the store clock" do
      lookup = store.lookup(key)

      expect(write_from(store, lookup, key, stored_at: lookup.now - 1_000)).to be(false)
      expect(store.lookup(key)).not_to be_found
    end
  end

  describe "#purge" do
    it "answers the new seq, one more per purge" do
      expect([store.purge([tag]), store.purge([other_tag, tag])]).to eq([1, 2])
      expect(store.lookup(key).seq).to eq(2)
    end

    it "refuses a write whose run looked up before a purge of one of its tags" do
      lookup = store.lookup(key)
      store.purge([tag])

      expect(write_from(store, lookup, key, tags: [other_tag, tag])).to be(false)
      expect(store.lookup(key)).not_to be_found
    end

    it "still accepts that write when the purge named none of its tags" do
      lookup = store.lookup(key)
      store.purge([other_tag])

      expect(write_from(store, lookup, key, tags: [tag])).to be(true)
    end

    it "accepts a write whose lookup came after the purge" do
      store.purge([tag])

      expect(store_after_lookup(store, key, tags: [tag]).last).to be(true)
    end

    it "answers the marks of an entry's tags purged after it was written, so a read rejects it" do
      lookup, = store_after_lookup(store, key, tags: [tag, other_tag])
      store.purge([tag])

      found = store.lookup(key)
      expect(found.marks).to eq(tag => 1)
      expect(found.marks.fetch(tag)).to be > lookup.seq
    end

    it "keeps a mark younger than max_ttl through later purges" do
      early = store.lookup(SecureRandom.hex(32))
      store.purge([tag])
      travel.call(600)
      store_after_lookup(store, key, tags: [tag])
      store.purge([other_tag])

      expect(store.lookup(key).marks).to eq(tag => 1)
      expect(write_from(store, early, SecureRandom.hex(32), tags: [tag])).to be(false)
    end

    if prunes
      it "prunes a mark once it is older than max_ttl, when every entry it could reject has expired" do
        store.purge([tag])
        travel.call(600)
        store_after_lookup(store, key, tags: [tag])
        travel.call(500)
        store.purge([other_tag])

        expect(store.lookup(key)).to have_attributes(blob: "blob", marks: {})
      end
    end

    it "never loses its epoch or a mark when the store fills with entries" do
      epoch = store.lookup(key).epoch
      early = store.lookup(key)
      store.purge([tag])
      200.times { |index| store_after_lookup(store, format("%064x", index), blob: "x" * 64, tags: [other_tag]) }

      expect(store.lookup(key).epoch).to eq(epoch)
      expect(write_from(store, early, key, tags: [tag])).to be(false)
    end
  end

  describe "#purge_all" do
    it "answers a new epoch and refuses every write looked up before it" do
      lookup = store.lookup(key)
      epoch = store.purge_all

      expect(epoch).to be_a(String).and(eq(store.lookup(key).epoch))
      expect(epoch).not_to eq(lookup.epoch)
      expect(write_from(store, lookup, key)).to be(false)
    end

    it "drops the marks, which the new epoch makes useless" do
      store.purge([tag])
      store.purge_all
      store_after_lookup(store, key, tags: [tag])

      expect(store.lookup(key).marks).to eq({})
    end
  end

  if meta_loss
    describe "a lost meta record" do
      it "is everything purged: a new epoch, so every entry stored before fails the epoch check" do
        lookup, = store_after_lookup(store, key)
        lose_meta.call

        after = store.lookup(key)
        expect(after.epoch).not_to eq(lookup.epoch)
        expect(after.seq).to eq(0)
        expect(write_from(store, lookup, SecureRandom.hex(32))).to be(false)
      end

      it "is created again by a write, refusing that write" do
        lookup = store.lookup(key)
        lose_meta.call

        expect(write_from(store, lookup, key)).to be(false)
        expect(store.lookup(key).epoch).not_to eq(lookup.epoch)
      end
    end

    describe "a seq that went back" do
      it "refuses a write whose seq is ahead of the store's, and answers the lower seq so a read rejects the entry" do
        3.times { store.purge([other_tag]) }
        lookup, = store_after_lookup(store, key)
        rewind_seq.call(1)

        expect(write_from(store, lookup, SecureRandom.hex(32))).to be(false)
        expect(store.lookup(key).seq).to eq(1).and(be < lookup.seq)
      end
    end
  end
end
