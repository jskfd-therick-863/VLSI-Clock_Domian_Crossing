# CDC waiver file. Each waiver suppresses one reported crossing.
# waive_cdc -id <CDC_ID> -reason <text> -owner <name> -expires <YYYY-MM-DD>
waive_cdc -id C03 -reason quasi_static_ack_sampled_twice -owner dft_team -expires 2027-03-31
waive_cdc -id C99 -reason legacy_block_removed_in_rtl2 -owner rtl_team -expires 2027-03-31
waive_cdc -id C03 -reason duplicate_entry_from_merge -owner rtl_team -expires 2027-03-31
waive_cdc -id C17 -reason temporary_until_gray_coder_lands -owner dsp_team -expires 2026-06-30
waive_cdc -id C05 -reason firmware_reads_status_slowly -owner sw_team -expires 2027-03-31
