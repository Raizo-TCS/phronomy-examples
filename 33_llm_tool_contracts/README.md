# LLM and Tool contracts without a provider service

From the repository root, set PHRONOMY_PATH to the matching unit 6 core checkout,
run `bundle install`, then `bundle exec ruby 33_llm_tool_contracts/run.rb`.
The result is `Result: 6`; no API key or LLM service is needed.

The local backend implements only protected operations. It returns a Tool request
as an ordinary Response. Agent validates and executes the Tool and calls the
backend again with a typed Tool-result message. Executable Tools and SDK Chat
objects never cross the backend operation boundary. The explicit JSON Schema
also rejects string/fractional/extra/missing arguments before execute.
