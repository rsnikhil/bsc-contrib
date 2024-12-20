// Copyright (c) 2020-2021 Bluespec, Inc. All Rights Reserved
//
// SPDX-License-Identifier: BSD-3-Clause

package AXI4_Widener;

// ================================================================
// This package defines an AXI4-S-to-AXI4-M 'widener' module.
// The interfaces facing S and M differ in data-bus width
// The S-side data bus is wider than the M-side by some multiple.

// The primary function is data-bus re-alignment due to widening.

// NOTE: Does not support bursts yet (which would need reshaping the
// data beats, strobes, burst lengh, etc.)

// ================================================================
// Bluespec library imports

import Vector       :: *;
import FIFOF        :: *;
import SpecialFIFOs :: *;
import ConfigReg    :: *;

// ----------------
// BSV additional libs

import Cur_Cycle  :: *;
import GetPut_Aux :: *;
import Semi_FIFOF :: *;

// ================================================================
// Project imports

import AXI4_Types :: *;

// ================================================================
// The interface for the widener module

interface AXI4_Widener_IFC #(numeric type wd_id_t,
			     numeric type wd_addr_t,
			     numeric type m_wd_data_t,    // narrower
			     numeric type s_wd_data_t,    // wider
			     numeric type wd_user_t);
   // From M
   interface AXI4_S_IFC  #(wd_id_t, wd_addr_t, m_wd_data_t, wd_user_t) from_M;
   // To S
   interface AXI4_M_IFC #(wd_id_t, wd_addr_t, s_wd_data_t, wd_user_t) to_S;
endinterface

// ================================================================
// The Widener module

module mkAXI4_Widener (AXI4_Widener_IFC #(wd_id_t, wd_addr_t, m_wd_data_t, s_wd_data_t, wd_user_t))
   provisos (Mul #(8, m_wd_bytes_t, m_wd_data_t),
	     Div #(m_wd_data_t, 8, m_wd_bytes_t),
	     Mul #(8, s_wd_bytes_t, s_wd_data_t),
	     Div #(s_wd_data_t, 8, s_wd_bytes_t),
	     Add #(m_wd_data_t,  __a, s_wd_data_t),     // m_wd_data <= s_wd_data ("widening")
	     Add #(m_wd_bytes_t, __b, s_wd_bytes_t),    // m_wd_bytes <= s_wd_bytes ("widening")
	     Log #(m_wd_bytes_t, log2_m_wd_bytes_t),
	     Log #(s_wd_bytes_t, log2_s_wd_bytes_t),
	     NumAlias #(word_index_t, TSub #(s_wd_bytes_t, m_wd_bytes_t)));

   // 0 quiet; 1: display rules
   Integer verbosity = 0;

   Integer log2_m_wd_bytes = valueOf (log2_m_wd_bytes_t);
   Integer log2_s_wd_bytes = valueOf (log2_s_wd_bytes_t);

   // ----------------
   // Transactor facing M
   AXI4_S_Xactor_IFC  #(wd_id_t, wd_addr_t, m_wd_data_t, wd_user_t)
      xactor_from_M <- mkAXI4_S_Xactor;

   // Transactor facing S
   AXI4_M_Xactor_IFC #(wd_id_t, wd_addr_t, s_wd_data_t, wd_user_t)
       xactor_to_S <- mkAXI4_M_Xactor;

   // size covers latency to mem read response
   FIFOF #(Bit #(wd_addr_t)) f_araddrs <- mkSizedFIFOF (8);

   // ----------------------------------------------------------------
   // BEHAVIOR

   // ----------------
   // Widen data and strobe from M to S

   function Tuple2 #(Bit #(s_wd_data_t),
		     Bit #(s_wd_bytes_t)) fv_align_to_wider (Bit #(wd_addr_t)     addr,
							     Bit #(m_wd_data_t)   m_data,
							     Bit #(m_wd_bytes_t)  m_strb);
      Bit #(word_index_t) shift_m_words  = addr [log2_s_wd_bytes - 1: log2_m_wd_bytes];
      Bit #(s_wd_data_t)  s_data         = zeroExtend (m_data);
      s_data = s_data << (shift_m_words * fromInteger (valueOf (m_wd_data_t)));

      Bit #(s_wd_bytes_t) s_strb = zeroExtend (m_strb);
      s_strb = s_strb << (shift_m_words * fromInteger (valueOf (m_wd_bytes_t)));
      return tuple2 (s_data, s_strb);
   endfunction

   // ----------------
   // Narrow data from S to M

   function Bit #(m_wd_data_t)
            fv_align_to_narrower (Bit #(wd_addr_t) addr, Bit #(s_wd_data_t) s_data);
      Bit #(word_index_t) shift_m_words = addr [log2_s_wd_bytes - 1: log2_m_wd_bytes];
      s_data = s_data >> (shift_m_words * fromInteger (valueOf (m_wd_data_t)));
      Bit #(m_wd_data_t) m_data  = truncate (s_data);
      return m_data;
   endfunction

   // ----------------
   // Wr requests (AW and W channels)

   rule rl_wr_xaction_M_to_S;
      AXI4_Wr_Addr #(wd_id_t, wd_addr_t, wd_user_t) m_wra <- pop_o (xactor_from_M.o_wr_addr);
      AXI4_Wr_Data #(m_wd_data_t, wd_user_t)        m_wrd <- pop_o (xactor_from_M.o_wr_data);

      let s_wra = m_wra;

      match { .s_wdata, .s_wstrb} = fv_align_to_wider (m_wra.awaddr, m_wrd.wdata, m_wrd.wstrb);
      AXI4_Wr_Data #(s_wd_data_t, wd_user_t) s_wrd = AXI4_Wr_Data {wdata: s_wdata,
								   wstrb: s_wstrb,
								   wlast: m_wrd.wlast,
								   wuser: m_wrd.wuser};
      // Send to S
      xactor_to_S.i_wr_addr.enq (s_wra);
      xactor_to_S.i_wr_data.enq (s_wrd);

      // Debugging
      if (verbosity > 0) begin
	 $display ("%0d: %m:AXI4_Widener.rl_wr_xaction_M_to_S: m -> s", cur_cycle);
	 $display ("    m_wra : ", fshow (m_wra));
	 $display ("    m_wrd: ",  fshow (m_wrd));
	 $display ("    s_wrd: ",  fshow (s_wrd));
      end
   endrule: rl_wr_xaction_M_to_S

   // ----------------
   // Wr responses (B channel): just pass through as-is.

   rule rl_wr_resp_S_to_M;
      AXI4_Wr_Resp #(wd_id_t, wd_user_t) s_wrr <- pop_o (xactor_to_S.o_wr_resp);
      let m_wrr = s_wrr;
      xactor_from_M.i_wr_resp.enq (m_wrr);

      if (verbosity > 1) begin
	 $display ("%0d: %m::AXI4_Widener.rl_wr_resp_S_to_M: m <- s", cur_cycle);
	 $display ("    s_wrr: ", fshow (s_wrr));
	 $display ("    m_wrr: ", fshow (m_wrr));
      end
   endrule

   // ----------------
   // Rd requests (AR channel); just pass it through, as-is
   // but remember the addr in order to align the data response.

   rule rl_rd_xaction_M_to_S;
      AXI4_Rd_Addr #(wd_id_t, wd_addr_t, wd_user_t) m_rda <- pop_o (xactor_from_M.o_rd_addr);
      let s_rda = m_rda;
      xactor_to_S.i_rd_addr.enq (s_rda);

      f_araddrs.enq (m_rda.araddr);

      // Debugging
      if (verbosity > 0) begin
	 $display ("%0d: %m::AXI4_Widener.rl_rd_xaction_M_to_S: m -> s", cur_cycle);
	 $display ("    m_rda: ", fshow (m_rda));
	 $display ("    s_rda: ", fshow (s_rda));
      end
   endrule: rl_rd_xaction_M_to_S

   // ----------------
   // Rd responses

   rule rl_rd_resp_S_to_M;
      AXI4_Rd_Data #(wd_id_t, s_wd_data_t, wd_user_t) s_rdd <- pop_o (xactor_to_S.o_rd_data);
      let araddr <- pop (f_araddrs);

      let m_rdata = fv_align_to_narrower (araddr, s_rdd.rdata);
      AXI4_Rd_Data #(wd_id_t, m_wd_data_t, wd_user_t) m_rdd = AXI4_Rd_Data {rid:   s_rdd.rid,
									    rdata: m_rdata,
									    rresp: s_rdd.rresp,
									    rlast: s_rdd.rlast,
									    ruser: s_rdd.ruser};
      xactor_from_M.i_rd_data.enq (m_rdd);

      // Debugging
      if (verbosity > 0) begin
	 $display ("%0d: %m::AXI4_Widener.rl_rd_resp_S_to_M: m <- s", cur_cycle);
	 $display ("    s_rdd: ", fshow (s_rdd));
	 $display ("    m_rdd: ", fshow (m_rdd));
      end
   endrule: rl_rd_resp_S_to_M

   // ----------------------------------------------------------------
   // INTERFACE

   interface from_M = xactor_from_M.axi_side;
   interface to_S   = xactor_to_S.axi_side;
endmodule

// ================================================================

endpackage: AXI4_Widener
