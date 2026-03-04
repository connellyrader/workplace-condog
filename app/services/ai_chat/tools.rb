module AiChat
  module Tools
    def self.definitions
      [
        # =======================================================================
        # SCORE TOOLS - Return aggregated, ready-to-use scores
        # =======================================================================

        {
          type: "function",
          function: {
            name: "global_score",
            description: "Get the global culture score plus all 6 metric scores for a 30-day window ending at end_date, aligned to dashboard card math. Returns scores, detection counts, and chart-aligned deltas (first-to-last point in the dashboard window). One call gives the full dashboard snapshot.",
            parameters: {
              type: "object",
              properties: {
                end_date: {
                  type: "string",
                  description: "End date for the 30-day window (YYYY-MM-DD). Defaults to today."
                },
                group_id: {
                  type: "integer",
                  description: "Optional Group id to scope results. Must have >= 3 members."
                }
              },
              required: []
            }
          }
        },

        {
          type: "function",
          function: {
            name: "metric_score",
            description: "Get metric scores for a 30-day window ending at end_date. If a specific metric is provided, returns that metric's score plus all its submetric scores. If no metric is specified, returns all metric scores for easy comparison.",
            parameters: {
              type: "object",
              properties: {
                metric: {
                  type: ["integer", "string"],
                  description: "Optional metric id or name (e.g., 'Conflict' or 5). If omitted, returns all metric scores."
                },
                end_date: {
                  type: "string",
                  description: "End date for the 30-day window (YYYY-MM-DD). Defaults to today."
                },
                group_id: {
                  type: "integer",
                  description: "Optional Group id to scope results. Must have >= 3 members."
                }
              },
              required: []
            }
          }
        },

        {
          type: "function",
          function: {
            name: "submetric_score",
            description: "Get submetric scores for a 30-day window ending at end_date. If a specific submetric is provided, returns that submetric's detailed score. If no submetric is specified, returns all submetric scores for easy comparison.",
            parameters: {
              type: "object",
              properties: {
                submetric: {
                  type: ["integer", "string"],
                  description: "Optional submetric id or name (e.g., 'Task Conflict' or 6). If omitted, returns all submetric scores."
                },
                end_date: {
                  type: "string",
                  description: "End date for the 30-day window (YYYY-MM-DD). Defaults to today."
                },
                group_id: {
                  type: "integer",
                  description: "Optional Group id to scope results. Must have >= 3 members."
                }
              },
              required: []
            }
          }
        },

        # =======================================================================
        # COMPARISON TOOLS - Compare across time or groups
        # =======================================================================

        {
          type: "function",
          function: {
            name: "compare_periods",
            description: "Compare scores between two time periods. Returns scores for both periods and the delta. Use for questions like 'How has X changed since last month?'",
            parameters: {
              type: "object",
              properties: {
                end_date_a: {
                  type: "string",
                  description: "End date for the first 30-day period (YYYY-MM-DD)."
                },
                end_date_b: {
                  type: "string",
                  description: "End date for the second 30-day period (YYYY-MM-DD)."
                },
                metric: {
                  type: ["integer", "string"],
                  description: "Optional metric id or name. If omitted, compares global score."
                },
                submetric: {
                  type: ["integer", "string"],
                  description: "Optional submetric id or name. If provided, compares that submetric."
                },
                group_id: {
                  type: "integer",
                  description: "Optional Group id to scope results."
                }
              },
              required: ["end_date_a", "end_date_b"]
            }
          }
        },

        {
          type: "function",
          function: {
            name: "compare_groups",
            description: "Compare scores across multiple groups/teams for the same time period. Returns each group's score and detection count. Use for questions like 'Which team has the lowest engagement?'",
            parameters: {
              type: "object",
              properties: {
                group_ids: {
                  type: "array",
                  items: { type: "integer" },
                  description: "Array of Group ids to compare. Each must have >= 3 members."
                },
                metric: {
                  type: ["integer", "string"],
                  description: "Optional metric id or name. If omitted, compares global score."
                },
                submetric: {
                  type: ["integer", "string"],
                  description: "Optional submetric id or name."
                },
                end_date: {
                  type: "string",
                  description: "End date for the 30-day window (YYYY-MM-DD). Defaults to today."
                }
              },
              required: ["group_ids"]
            }
          }
        },

        # =======================================================================
        # TREND TOOLS - Time series and trend analysis
        # =======================================================================

        {
          type: "function",
          function: {
            name: "trend_series",
            description: "Get a time series of scores for trend analysis or charting. Returns data points at the specified interval with a trend direction label (improving/declining/stable).",
            parameters: {
              type: "object",
              properties: {
                metric: {
                  type: ["integer", "string"],
                  description: "Optional metric id or name. If omitted, returns global score trend."
                },
                submetric: {
                  type: ["integer", "string"],
                  description: "Optional submetric id or name."
                },
                start_date: {
                  type: "string",
                  description: "Start date for the series (YYYY-MM-DD)."
                },
                end_date: {
                  type: "string",
                  description: "End date for the series (YYYY-MM-DD). Defaults to today."
                },
                interval: {
                  type: "string",
                  enum: ["daily", "weekly"],
                  description: "Data point interval. Default: weekly."
                },
                group_id: {
                  type: "integer",
                  description: "Optional Group id to scope results."
                }
              },
              required: ["start_date"]
            }
          }
        },

        # =======================================================================
        # CATALOG TOOLS - Discovery and lookup
        # =======================================================================

        {
          type: "function",
          function: {
            name: "list_metrics",
            description: "List all available top-level metrics with their ids, names, and descriptions.",
            parameters: {
              type: "object",
              properties: {
                query: {
                  type: "string",
                  description: "Optional substring filter to search metric names."
                }
              },
              required: []
            }
          }
        },

        {
          type: "function",
          function: {
            name: "list_submetrics",
            description: "List available submetrics, optionally filtered by metric. Returns ids, names, and parent metric.",
            parameters: {
              type: "object",
              properties: {
                metric: {
                  type: ["integer", "string"],
                  description: "Optional metric id or name to filter submetrics."
                },
                query: {
                  type: "string",
                  description: "Optional substring filter to search submetric names."
                }
              },
              required: []
            }
          }
        },

        {
          type: "function",
          function: {
            name: "list_groups",
            description: "List org groups available to the user with their ids, names, and member counts.",
            parameters: {
              type: "object",
              properties: {
                query: {
                  type: "string",
                  description: "Optional substring filter to search group names."
                }
              },
              required: []
            }
          }
        },

        {
          type: "function",
          function: {
            name: "list_signal_categories",
            description: "List available signal categories with their ids, names, and parent submetric/metric info.",
            parameters: {
              type: "object",
              properties: {
                query: {
                  type: "string",
                  description: "Optional substring filter to search signal category names."
                },
                submetric: {
                  type: ["integer", "string"],
                  description: "Optional submetric id or name to filter signal categories."
                }
              },
              required: []
            }
          }
        },

        {
          type: "function",
          function: {
            name: "signal_category_score",
            description: "Get a signal category's score for a 30-day window ending at end_date. If no signal_category is specified, returns all signal category scores.",
            parameters: {
              type: "object",
              properties: {
                signal_category: {
                  type: ["integer", "string"],
                  description: "Signal category id or name. If omitted, returns all signal category scores."
                },
                end_date: {
                  type: "string",
                  description: "End date for the 30-day window (YYYY-MM-DD). Defaults to today."
                },
                group_id: {
                  type: "integer",
                  description: "Optional Group id to scope results. Must have >= 3 members."
                }
              },
              required: []
            }
          }
        },

        # =======================================================================
        # INSIGHT TOOLS - Pre-calculated comparisons and rankings
        # =======================================================================

        {
          type: "function",
          function: {
            name: "score_delta",
            description: "Get a score with change vs a comparison period. Returns current score, previous score, delta, and direction (improving/declining/stable). Use for questions like 'Is X getting better or worse?'",
            parameters: {
              type: "object",
              properties: {
                scope: {
                  type: "string",
                  enum: ["global", "metric", "submetric", "signal_category"],
                  description: "What level to get delta for. Default: global."
                },
                name: {
                  type: ["integer", "string"],
                  description: "Name or id of the metric/submetric/signal_category (required unless scope is global)."
                },
                compare: {
                  type: "string",
                  enum: ["30d", "90d", "yoy"],
                  description: "Comparison period: 30d (vs prior 30 days), 90d (vs prior 90 days), yoy (vs same period last year). Default: 30d."
                },
                group_id: {
                  type: "integer",
                  description: "Optional Group id to scope results."
                }
              },
              required: []
            }
          }
        },

        {
          type: "function",
          function: {
            name: "top_movers",
            description: "Get the metrics/submetrics that have changed the most. Returns ranked list with deltas. Use for questions like 'What's changed the most?'",
            parameters: {
              type: "object",
              properties: {
                direction: {
                  type: "string",
                  enum: ["improving", "declining", "both"],
                  description: "Filter by direction of change. Default: both."
                },
                scope: {
                  type: "string",
                  enum: ["metric", "submetric"],
                  description: "What level to analyze. Default: metric."
                },
                limit: {
                  type: "integer",
                  description: "Max results to return. Default: 5."
                },
                group_id: {
                  type: "integer",
                  description: "Optional Group id to scope results."
                }
              },
              required: []
            }
          }
        },

        {
          type: "function",
          function: {
            name: "group_gaps",
            description: "Compare scores across all groups/teams and identify gaps. Returns ranked groups with scores and gap analysis. Use for questions like 'Which teams are struggling?'",
            parameters: {
              type: "object",
              properties: {
                scope: {
                  type: "string",
                  enum: ["global", "metric", "submetric"],
                  description: "What level to compare. Default: global."
                },
                name: {
                  type: ["integer", "string"],
                  description: "Name or id of the metric/submetric (required unless scope is global)."
                }
              },
              required: []
            }
          }
        }


        # =======================================================================
        # COMMENTED OUT - Legacy tools kept for reference
        # These were too "provide all the evidence" and caused GPT to make
        # wonky decisions when aggregating raw data. The new tools above
        # return pre-aggregated results instead.
        # =======================================================================

        # {
        #   type: "function",
        #   function: {
        #     name: "metrics_overview",
        #     description: "Executive overview of all top-level culture metrics over a period, including positive %, trends vs a comparison window, and the strongest and riskiest metrics.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_names: { type: "array", items: { type: "string" } },
        #         metric_ids:   { type: "array", items: { type: "integer" } },
        #         comparison_start_date: { type: "string" },
        #         comparison_end_date:   { type: "string" },
        #         comparison_window_days: { type: "integer" },
        #         categories:        { type: "array", items: { type: "string" } },
        #         category_ids:      { type: "array", items: { type: "integer" } },
        #         submetric_names:   { type: "array", items: { type: "string" } },
        #         submetric_ids:     { type: "array", items: { type: "integer" } },
        #         subcategory_names: { type: "array", items: { type: "string" } },
        #         subcategory_ids:   { type: "array", items: { type: "integer" } }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "metrics_trend",
        #     description: "Multi-metric trend analysis over a longer window (for example 60–90 days), returning time series and change flags for each top-level metric.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric:     { type: "string", enum: ["pos_rate","neg_rate","avg_logit","total"], default: "pos_rate" },
        #         metric_names: { type: "array", items: { type: "string" } },
        #         metric_ids:   { type: "array", items: { type: "integer" } },
        #         series: {
        #           type: "array",
        #           items: {
        #             type: "object",
        #             properties: {
        #               label:        { type: "string" },
        #               metric_name:  { type: "string" },
        #               metric_id:    { type: "integer" },
        #               category:     { type: "string" },
        #               submetric_name:   { type: "string" },
        #               submetric_id:     { type: "integer" },
        #               subcategory_name: { type: "string" },
        #               subcategory_id:   { type: "integer" }
        #             }
        #           }
        #         },
        #         cadence: { type: "string", enum: ["day","week"], default: "day" },
        #         top_n:   { type: "integer" }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "period_comparison",
        #     description: "Compare two explicit time windows (for example last 30 days vs previous 30 days) across metrics, submetrics, or signal categories.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         group_by: { type: "string", enum: ["category","metric","submetric","subcategory"], default: "metric" },
        #
        #         categories:        { type: "array", items: { type: "string" } },
        #         metric_names:      { type: "array", items: { type: "string" } },
        #         submetric_names:   { type: "array", items: { type: "string" } },
        #         subcategory_names: { type: "array", items: { type: "string" } },
        #
        #         metric_ids:        { type: "array", items: { type: "integer" } },
        #         submetric_ids:     { type: "array", items: { type: "integer" } },
        #         subcategory_ids:   { type: "array", items: { type: "integer" } },
        #
        #         period_a: {
        #           type: "object",
        #           properties: { start_date: { type: "string" }, end_date: { type: "string" } },
        #           required: ["start_date","end_date"]
        #         },
        #         period_b: {
        #           type: "object",
        #           properties: { start_date: { type: "string" }, end_date: { type: "string" } },
        #           required: ["start_date","end_date"]
        #         }
        #       },
        #       required: ["period_a","period_b"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "key_takeaways",
        #     description: "Generate 2–4 executive-ready bullets capturing the most important culture risks and strengths over a period, grounded in actual metric levels and changes.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         comparison_start_date: { type: "string" },
        #         comparison_end_date:   { type: "string" },
        #         comparison_window_days: { type: "integer" },
        #         focus_metrics: { type: "array", items: { type: "string" } },
        #         max_bullets:  { type: "integer", default: 3 }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "metric_deep_dive",
        #     description: "In-depth analysis for a single metric over a period, including overall score, submetric breakdown, key negative drivers, and how it compares to other metrics.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_name: { type: "string" },
        #         metric_id:   { type: "integer" },
        #         top_driver_count: { type: "integer", default: 5 },
        #         categories:        { type: "array", items: { type: "string" } },
        #         category_ids:      { type: "array", items: { type: "integer" } },
        #         submetric_names:   { type: "array", items: { type: "string" } },
        #         submetric_ids:     { type: "array", items: { type: "integer" } },
        #         subcategory_names: { type: "array", items: { type: "string" } },
        #         subcategory_ids:   { type: "array", items: { type: "integer" } }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "submetric_breakdown",
        #     description: "Drill into all submetrics under a top-level metric, sorted by performance and annotated with their top negative signal categories.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_name: { type: "string" },
        #         metric_id:   { type: "integer" },
        #         top_signals_per_submetric: { type: "integer", default: 3 }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "top_signals",
        #     description: "Return the highest-impact signal categories or subcategories in a given scope (overall, by metric, or by submetric) over a period.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         scope:      { type: "string", enum: ["overall","metric","submetric","subcategory"], default: "metric" },
        #         metric_name:      { type: "string" },
        #         metric_id:        { type: "integer" },
        #         submetric_name:   { type: "string" },
        #         submetric_id:     { type: "integer" },
        #         subcategory_name: { type: "string" },
        #         subcategory_id:   { type: "integer" },
        #         direction:  { type: "string", enum: ["negative","positive"], default: "negative" },
        #         top_n:      { type: "integer", default: 10 }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "signal_explain",
        #     description: "Look up the plain-language definition and any supporting templates or research for a metric, submetric, signal category, or subcategory.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         metric_name:      { type: "string" },
        #         submetric_name:   { type: "string" },
        #         signal_category:  { type: "string" },
        #         signal_subcategory: { type: "string" },
        #         query:            { type: "string", description: "Fallback text query when an exact name is not known." }
        #       },
        #       required: []
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "time_series_data",
        #     description: "Return day-by-day or week-by-week time series data for one metric, submetric, or signal category over a window.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         category:          { type: "string" },
        #         metric_names:      { type: "array", items: { type: "string" } },
        #         submetric_names:   { type: "array", items: { type: "string" } },
        #         subcategory_names: { type: "array", items: { type: "string" } },
        #
        #         metric_ids:        { type: "array", items: { type: "integer" } },
        #         submetric_ids:     { type: "array", items: { type: "integer" } },
        #         subcategory_ids:   { type: "array", items: { type: "integer" } },
        #
        #         start_date:  { type: "string" },
        #         end_date:    { type: "string" },
        #         metric:      { type: "string", enum: ["pos_rate","neg_rate","avg_logit","total"], default: "pos_rate" }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "sparkline_chart",
        #     description: "Generate a lightweight sparkline or chart image for a single metric or signal, returning chart metadata and an embeddable URL.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         category:          { type: "string" },
        #         metric_name:       { type: "string" },
        #         metric_id:         { type: "integer" },
        #         submetric_name:    { type: "string" },
        #         submetric_id:      { type: "integer" },
        #         subcategory_name:  { type: "string" },
        #         subcategory_id:    { type: "integer" },
        #         start_date:        { type: "string" },
        #         end_date:          { type: "string" },
        #         metric:            { type: "string", enum: ["pos_rate","neg_rate","avg_logit","total"], default: "pos_rate" }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "stats_analysis",
        #     description: "Perform simple trend and inflection analysis on one or more time series to determine whether changes look meaningful or just noisy.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         series: {
        #           type: "array",
        #           minItems: 1,
        #           items: {
        #             type: "object",
        #             properties: {
        #               label: { type: "string" },
        #               metric: { type: "string", enum: ["pos_rate","neg_rate","avg_logit","total"], default: "pos_rate" },
        #               points: {
        #                 type: "array",
        #                 items: {
        #                   type: "object",
        #                   properties: {
        #                     date:  { type: "string" },
        #                     value: { type: "number" }
        #                   },
        #                   required: ["date","value"]
        #                 }
        #               }
        #             },
        #             required: ["points"]
        #           }
        #         }
        #       },
        #       required: ["series"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "group_comparison",
        #     description: "Compare one or more metrics across Groups defined in the platform (for example Leaders vs ICs) over a period.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_name:{ type: "string" },
        #         metric_id:  { type: "integer" },
        #         segments: {
        #           type: "array",
        #           minItems: 1,
        #           items: {
        #             type: "object",
        #             properties: {
        #               label:        { type: "string" },
        #               group_ids:    { type: "array", items: { type: "integer" } },
        #               group_names:  { type: "array", items: { type: "string" } }
        #             },
        #             required: []
        #           }
        #         }
        #       },
        #       required: ["start_date","end_date","segments"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "top_group_signals",
        #     description: "Rank Groups by how strongly a given metric or signal category shows up within them over a period.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_name:{ type: "string" },
        #         metric_id:  { type: "integer" },
        #         signal_category: { type: "string" },
        #         signal_category_id: { type: "integer" },
        #         top_n_groups: { type: "integer", default: 5 },
        #         segments: {
        #           type: "array",
        #           minItems: 1,
        #           items: {
        #             type: "object",
        #             properties: {
        #               label:        { type: "string" },
        #               group_ids:    { type: "array", items: { type: "integer" } },
        #               group_names:  { type: "array", items: { type: "string" } }
        #             }
        #           }
        #         }
        #       },
        #       required: ["start_date","end_date","segments"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "segment_trend",
        #     description: "Parallel time-series view comparing a metric across two or more Groups (for example Leaders vs ICs) over the same window.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_name:{ type: "string" },
        #         metric_id:  { type: "integer" },
        #         cadence:    { type: "string", enum: ["day","week"], default: "day" },
        #         segments: {
        #           type: "array",
        #           minItems: 2,
        #           items: {
        #             type: "object",
        #             properties: {
        #               label:        { type: "string" },
        #               group_ids:    { type: "array", items: { type: "integer" } },
        #               group_names:  { type: "array", items: { type: "string" } }
        #             }
        #           }
        #         }
        #       },
        #       required: ["start_date","end_date","segments"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "group_trends",
        #     description: "Rank org groups by how a metric is trending over a window and return per-group time series plus start/end values.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_names: { type: "array", items: { type: "string" } },
        #         metric_ids:   { type: "array", items: { type: "integer" } },
        #         metric:       { type: "string", enum: ["pos_rate","neg_rate","avg_logit","total"], default: "pos_rate" },
        #         group_ids:   { type: "array", items: { type: "integer" } },
        #         group_names: { type: "array", items: { type: "string" } },
        #         top_n:       { type: "integer", description: "How many top movers to highlight (default 5)." },
        #         cadence:     { type: "string", enum: ["day","week"], default: "week" }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "event_impact",
        #     description: "Measure how culture metrics shifted in a before/after window around a key event date (for example a reorg or policy launch).",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         event_date: { type: "string" },
        #         pre_days:   { type: "integer", default: 14 },
        #         post_days:  { type: "integer", default: 14 },
        #         metric_names: { type: "array", items: { type: "string" } },
        #         metric_ids:   { type: "array", items: { type: "integer" } }
        #       },
        #       required: ["event_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "multi_event_analysis",
        #     description: "Compare the impact of the same metric or set of metrics across multiple events, each with its own before/after window.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         metrics: {
        #           type: "array",
        #           items: { type: "string" },
        #           description: "Names of metrics to analyze (for example ['Execution Risk','Burnout'])."
        #         },
        #         metric_ids: {
        #           type: "array",
        #           items: { type: "integer" }
        #         },
        #         events: {
        #           type: "array",
        #           minItems: 1,
        #           items: {
        #             type: "object",
        #             properties: {
        #               label: { type: "string" },
        #               date:  { type: "string" },
        #               pre_days:  { type: "integer", default: 14 },
        #               post_days: { type: "integer", default: 14 }
        #             },
        #             required: ["date"]
        #           }
        #         }
        #       },
        #       required: ["events"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "keyword_filter",
        #     description: "Filter culture metrics to only messages tagged with specific references or themes (for example 'office', 'remote', 'layoffs') and compute metrics within that slice.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         keywords:   { type: "array", items: { type: "string" } },
        #         metric_names: { type: "array", items: { type: "string" } },
        #         metric_ids:   { type: "array", items: { type: "integer" } }
        #       },
        #       required: ["start_date","end_date","keywords"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "correlation_analysis",
        #     description: "Analyze how two or more metrics move together over time, including simple correlation and co-movement patterns.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         metric_names: {
        #           type: "array",
        #           minItems: 2,
        #           items: { type: "string" },
        #           description: "Human-readable metric names, for example ['Psychological Safety','Conflict']."
        #         },
        #         metric_ids: {
        #           type: "array",
        #           minItems: 2,
        #           items: { type: "integer" },
        #           description: "Explicit metric IDs when available; overrides metric_names if present."
        #         },
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         categories:        { type: "array", items: { type: "string" } },
        #         category_ids:      { type: "array", items: { type: "integer" } },
        #         submetric_names:   { type: "array", items: { type: "string" } },
        #         submetric_ids:     { type: "array", items: { type: "integer" } },
        #         subcategory_names: { type: "array", items: { type: "string" } },
        #         subcategory_ids:   { type: "array", items: { type: "integer" } },
        #         cadence: {
        #           type: "string",
        #           enum: ["day","week"],
        #           default: "day",
        #           description: "Aggregation grain for any returned time series."
        #         },
        #         include_timeseries: {
        #           type: "boolean",
        #           default: true,
        #           description: "Whether to include sparkline-ready time series for each metric."
        #         },
        #         include_co_movement: {
        #           type: "boolean",
        #           default: true,
        #           description: "Whether to compute simple co-movement stats (for example days where both move up or down)."
        #         }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "leading_indicator",
        #     description: "Identify signal categories that tend to spike ahead of a target metric worsening, as potential early warning indicators.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_name:{ type: "string" },
        #         metric_id:  { type: "integer" },
        #         lookback_days: { type: "integer" },
        #         top_n: { type: "integer" }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "root_cause_analysis",
        #     description: "For a concerning metric, surface the top signal categories and themes most likely driving the issue in a given period.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_names: { type: "array", items: { type: "string" } },
        #         metric_ids:   { type: "array", items: { type: "integer" } },
        #         query:        { type: "string" },
        #         max_recommendations: { type: "integer" }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "misalignment_detector",
        #     description: "Detect misalignment between leadership and IC segments (or other group splits) by comparing sentiment gaps on key metrics.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_names: { type: "array", items: { type: "string" } },
        #         metric_ids:   { type: "array", items: { type: "integer" } },
        #         leader_segment: {
        #           type: "object",
        #           description: "Group segment representing leaders or management.",
        #           properties: {
        #             label:        { type: "string" },
        #             group_ids:    { type: "array", items: { type: "integer" } },
        #             group_names:  { type: "array", items: { type: "string" } }
        #           }
        #         },
        #         ic_segment: {
        #           type: "object",
        #           description: "Group segment representing individual contributors or the broader population.",
        #           properties: {
        #             label:        { type: "string" },
        #             group_ids:    { type: "array", items: { type: "integer" } },
        #             group_names:  { type: "array", items: { type: "string" } }
        #           }
        #         }
        #       },
        #       required: ["start_date","end_date","leader_segment","ic_segment"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "recommendation_generator",
        #     description: "Generate a short list of concrete actions or coaching tips tied to the biggest culture risks in the selected window.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         start_date: { type: "string" },
        #         end_date:   { type: "string" },
        #         metric_names: { type: "array", items: { type: "string" } },
        #         metric_ids:   { type: "array", items: { type: "integer" } },
        #         query:        { type: "string" },
        #         max_recommendations: { type: "integer", default: 3 }
        #       },
        #       required: ["start_date","end_date"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "knowledge_base_query",
        #     description: "Retrieve external research snippets or benchmark insights from the culture knowledge base for a given topic or question.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         query: { type: "string" },
        #         kinds: { type: "array", items: { type: "string",
        #                  enum: ["metric","submetric","signal_category","signal_subcategory"] } }
        #       },
        #       required: ["query"]
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "benchmark_comparison",
        #     description: "Compare internal culture metrics to any available external or historical benchmarks, where such benchmarks have been configured.",
        #     parameters: {
        #       type: "object",
        #       properties: {
        #         metric_names: { type: "array", items: { type: "string" } },
        #         metric_ids:   { type: "array", items: { type: "integer" } },
        #         benchmark_set: { type: "string", description: "Optional named benchmark set or industry segment to compare against." }
        #       },
        #       required: []
        #     }
        #   }
        # },
        # {
        #   type: "function",
        #   function: {
        #     name: "list_widgets",
        #     description: "List the inline visualization widgets you can embed with {{widget:NAME ...}} placeholders, including their names, purpose, and expected parameters.",
        #     parameters: {
        #       type: "object",
        #       properties: {},
        #       required: []
        #     }
        #   }
        # }
      ]
    end

    # -------------------- Vector store + Responses tools --------------------

    VECTOR_STORE_ID = ENV.fetch(
      "OPENAI_VECTOR_STORE_ID",
      "vs_68fb72635c9c8191a4fb315e356d496a"
    )

    def self.file_search_tool
      return nil if VECTOR_STORE_ID.to_s.strip.empty?

      {
        type: "file_search",
        vector_store_ids: [VECTOR_STORE_ID]
      }
    end

    def self.for_responses
      fn_tools =
        definitions.map do |tool|
          next tool unless tool[:type].to_s == "function" && tool[:function].is_a?(Hash)

          fn = tool[:function]
          h = {
            type:        "function",
            name:        fn[:name],
            description: fn[:description],
            parameters:  fn[:parameters]
          }
          h[:strict] = fn[:strict] if fn.key?(:strict)
          h
        end

      tools = fn_tools.compact
      if (fs = file_search_tool)
        tools << fs
      end
      tools
    end
  end
end
