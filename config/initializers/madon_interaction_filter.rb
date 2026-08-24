# frozen_string_literal: true

# madon Phase 1 — drop inbound `Like`, `Announce`, reply-style `Create`, and
# `QuoteRequest` activities targeting LOCAL statuses when the source actor's
# domain isn't in the trusted set. Without this, a boost, favourite, or quote
# from anywhere on the wider fediverse moves the count on a local toot —
# defeating the load-bearing PoC claim that "10 boosts = 10 real verified
# people". (v4.5 added quote posts: an inbound QuoteRequest on a local status
# increments quotes_count and fires a `quote` notification.)
#
# We reuse Mastodon's existing `DomainAllow` model for the trusted set.
# DomainAllow is normally only consulted when the instance runs in
# limited-federation mode; here the instance federates openly and we
# read DomainAllow purely as the trusted-network allow-list. Empty by
# default → every inbound interaction on a local status gets dropped.
# Add a peer's domain via /admin/domain_allows to start counting from
# that peer.
#
# Outbound is untouched: a local user's own Like / Announce / Create
# never reaches these handlers (those go through the local `Status` /
# `Favourite` paths, which only enqueue federation deliveries). So our
# users keep enjoying the wider fediverse — only inbound counting is
# gated. See README.md (Phase 1) for the design.

Rails.application.config.to_prepare do
  ActivityPub::Activity::Like.prepend(Module.new do
    def perform
      return if @account.domain.present? && !DomainAllow.allowed?(@account.domain)

      super
    end
  end)

  ActivityPub::Activity::Announce.prepend(Module.new do
    def perform
      if @account.domain.present? && !DomainAllow.allowed?(@account.domain)
        original = status_from_object
        return reject_payload! if original&.local?
      end

      super
    end
  end)

  ActivityPub::Activity::QuoteRequest.prepend(Module.new do
    def perform
      if @account.domain.present? && !DomainAllow.allowed?(@account.domain)
        quoted = status_from_uri(object_uri)
        return reject_payload! if quoted&.local?
      end

      super
    end
  end)

  ActivityPub::Activity::Create.prepend(Module.new do
    def perform
      if @account.domain.present? && !DomainAllow.allowed?(@account.domain) && @object.is_a?(Hash)
        in_reply_to_uri = value_or_id(@object['inReplyTo'])
        if in_reply_to_uri.present?
          replied_to = status_from_uri(in_reply_to_uri)
          return reject_payload! if replied_to&.local?
        end
      end

      super
    end
  end)
end
