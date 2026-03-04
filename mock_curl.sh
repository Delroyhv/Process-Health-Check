#!/bin/bash
# Check if it's a range query or single query
if [[ "$*" == *"query_range"* ]]; then
  # Return range query format
  echo '{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"__name__":"test_metric"},"values":[[1700000000,"90"],[1700000300,"40"]]}]}}'
else
  # Return single query format (e.g. for oldest timestamp check)
  if [[ "$*" == *"prometheus_tsdb_lowest_timestamp_seconds"* ]]; then
    echo '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1700000000,"1700000000"]}]}}'
  else
    echo '{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"test_metric"},"value":[1700000000,"90"]}]}}'
  fi
fi
