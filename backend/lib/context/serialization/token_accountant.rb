# frozen_string_literal: true

module Context
  module Serialization
    # Estimates the rendered size of a response and hashes what was rendered.
    #
    # This is an estimate and is labelled as one. The estimator version travels
    # with every number so a later, better estimator does not silently change
    # the meaning of recorded packet accounting, and the heuristic below is not
    # a model tokenizer: it is a stable, cheap proxy used to enforce subsystem
    # budgets, never to claim what a model actually consumed.
    module TokenAccountant
      ESTIMATOR_VERSION = "kioku.tokens.v1-heuristic-chars-per-token-4"
      CHARS_PER_TOKEN = 4

      module_function

      def estimate(rendered)
        text = rendered.is_a?(String) ? rendered : Contracts::Canonical.encode(rendered)
        {
          "estimated_tokens" => (text.length.to_f / CHARS_PER_TOKEN).ceil,
          "estimator_version" => ESTIMATOR_VERSION,
          "rendered_hash" => Contracts::Canonical.hex(text)
        }
      end

      # budget is the caller's token_budget when supplied. Exceeding it is a
      # coverage gap (token_budget) and a partial result, never a silent trim.
      def account(rendered, budget: nil)
        estimate(rendered).merge("budget" => budget)
      end

      def over_budget?(accounting)
        budget = accounting["budget"]
        !budget.nil? && accounting["estimated_tokens"] > budget
      end
    end
  end
end
