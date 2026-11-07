export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      business_audit: {
        Row: {
          action: string
          actor: string
          after_data: Json | null
          before_data: Json | null
          created_at: string
          entity: string | null
          entity_id: string | null
          id: string
          reason: string | null
        }
        Insert: {
          action: string
          actor: string
          after_data?: Json | null
          before_data?: Json | null
          created_at?: string
          entity?: string | null
          entity_id?: string | null
          id?: string
          reason?: string | null
        }
        Update: {
          action?: string
          actor?: string
          after_data?: Json | null
          before_data?: Json | null
          created_at?: string
          entity?: string | null
          entity_id?: string | null
          id?: string
          reason?: string | null
        }
        Relationships: []
      }
      business_exports: {
        Row: {
          actor: string
          created_at: string
          id: string
          snapshot: Json
        }
        Insert: {
          actor: string
          created_at?: string
          id?: string
          snapshot: Json
        }
        Update: {
          actor?: string
          created_at?: string
          id?: string
          snapshot?: Json
        }
        Relationships: []
      }
      dealer_ai_access: {
        Row: {
          denial_message: string
          id: boolean
          status: number
          updated_at: string
        }
        Insert: {
          denial_message: string
          id?: boolean
          status: number
          updated_at?: string
        }
        Update: {
          denial_message?: string
          id?: boolean
          status?: number
          updated_at?: string
        }
        Relationships: []
      }
      dealer_blocks: {
        Row: {
          blocked: boolean
          confirmed_at: string
          confirmed_by: string
          retailer_id: string
        }
        Insert: {
          blocked?: boolean
          confirmed_at?: string
          confirmed_by: string
          retailer_id: string
        }
        Update: {
          blocked?: boolean
          confirmed_at?: string
          confirmed_by?: string
          retailer_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "dealer_blocks_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: true
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
        ]
      }
      dealer_risk_assessments: {
        Row: {
          action_bn: string
          action_en: string
          assessed_at: string
          assessed_by: string
          facts: Json
          model: string
          reason_bn: string
          reason_en: string
          retailer_id: string
          score: number
        }
        Insert: {
          action_bn: string
          action_en: string
          assessed_at?: string
          assessed_by: string
          facts: Json
          model: string
          reason_bn: string
          reason_en: string
          retailer_id: string
          score: number
        }
        Update: {
          action_bn?: string
          action_en?: string
          assessed_at?: string
          assessed_by?: string
          facts?: Json
          model?: string
          reason_bn?: string
          reason_en?: string
          retailer_id?: string
          score?: number
        }
        Relationships: [
          {
            foreignKeyName: "dealer_risk_assessments_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: true
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
        ]
      }
      deposits: {
        Row: {
          client_op_id: string | null
          method: string
          receipt_no: string | null
          txn_date: string
          amount: number
          created_at: string
          id: string
          note: string | null
          received_by: string | null
          salesman_id: string
        }
        Insert: {
          client_op_id?: string | null
          method?: string
          receipt_no?: string | null
          txn_date?: string
          amount: number
          created_at?: string
          id?: string
          note?: string | null
          received_by?: string | null
          salesman_id: string
        }
        Update: {
          client_op_id?: string | null
          method?: string
          receipt_no?: string | null
          txn_date?: string
          amount?: number
          created_at?: string
          id?: string
          note?: string | null
          received_by?: string | null
          salesman_id?: string
        }
        Relationships: []
      }
      imei_units: {
        Row: {
          cost_price: number
          purchase_id: string | null
          supplier_id: string | null
          created_at: string
          id: string
          imei: string
          product_id: string
          retailer_id: string | null
          salesman_id: string | null
          status: Database["public"]["Enums"]["imei_status"]
        }
        Insert: {
          cost_price?: number
          purchase_id?: string | null
          supplier_id?: string | null
          created_at?: string
          id?: string
          imei: string
          product_id: string
          retailer_id?: string | null
          salesman_id?: string | null
          status?: Database["public"]["Enums"]["imei_status"]
        }
        Update: {
          cost_price?: number
          purchase_id?: string | null
          supplier_id?: string | null
          created_at?: string
          id?: string
          imei?: string
          product_id?: string
          retailer_id?: string | null
          salesman_id?: string | null
          status?: Database["public"]["Enums"]["imei_status"]
        }
        Relationships: [
          {
            foreignKeyName: "imei_units_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      products: {
        Row: {
          cost_price: number
          created_at: string
          id: string
          is_smartphone: boolean
          low_stock_threshold: number
          model: string | null
          name: string
          price: number
          stock_qty: number
        }
        Insert: {
          cost_price?: number
          created_at?: string
          id?: string
          is_smartphone?: boolean
          low_stock_threshold?: number
          model?: string | null
          name: string
          price?: number
          stock_qty?: number
        }
        Update: {
          cost_price?: number
          created_at?: string
          id?: string
          is_smartphone?: boolean
          low_stock_threshold?: number
          model?: string | null
          name?: string
          price?: number
          stock_qty?: number
        }
        Relationships: []
      }
      profiles: {
        Row: {
          active: boolean
          created_at: string
          full_name: string
          id: string
          phone: string | null
        }
        Insert: {
          active?: boolean
          created_at?: string
          full_name?: string
          id: string
          phone?: string | null
        }
        Update: {
          active?: boolean
          created_at?: string
          full_name?: string
          id?: string
          phone?: string | null
        }
        Relationships: []
      }
      retailer_payments: {
        Row: {
          client_op_id: string | null
          method: string
          receipt_no: string | null
          txn_date: string
          amount: number
          created_at: string
          id: string
          note: string | null
          retailer_id: string
          salesman_id: string
        }
        Insert: {
          client_op_id?: string | null
          method?: string
          receipt_no?: string | null
          txn_date?: string
          amount: number
          created_at?: string
          id?: string
          note?: string | null
          retailer_id: string
          salesman_id?: string
        }
        Update: {
          client_op_id?: string | null
          method?: string
          receipt_no?: string | null
          txn_date?: string
          amount?: number
          created_at?: string
          id?: string
          note?: string | null
          retailer_id?: string
          salesman_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "retailer_payments_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: false
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
        ]
      }
      retailers: {
        Row: {
          credit_limit: number | null
          due_days: number
          address: string | null
          created_at: string
          id: string
          name: string
          phone: string | null
          salesman_id: string
        }
        Insert: {
          credit_limit?: number | null
          due_days?: number
          address?: string | null
          created_at?: string
          id?: string
          name: string
          phone?: string | null
          salesman_id?: string
        }
        Update: {
          credit_limit?: number | null
          due_days?: number
          address?: string | null
          created_at?: string
          id?: string
          name?: string
          phone?: string | null
          salesman_id?: string
        }
        Relationships: []
      }
      sales: {
        Row: {
          client_op_id: string | null
          discount: number
          invoice_no: string | null
          txn_date: string
          created_at: string
          id: string
          paid: number
          retailer_id: string
          salesman_id: string
          total: number
        }
        Insert: {
          client_op_id?: string | null
          discount?: number
          invoice_no?: string | null
          txn_date?: string
          created_at?: string
          id?: string
          paid?: number
          retailer_id: string
          salesman_id: string
          total?: number
        }
        Update: {
          client_op_id?: string | null
          discount?: number
          invoice_no?: string | null
          txn_date?: string
          created_at?: string
          id?: string
          paid?: number
          retailer_id?: string
          salesman_id?: string
          total?: number
        }
        Relationships: [
          {
            foreignKeyName: "sales_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: false
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_movements: {
        Row: {
          batch_no: string | null
          cost_price: number | null
          txn_date: string
          created_at: string
          id: string
          imei: string | null
          kind: Database["public"]["Enums"]["move_kind"]
          product_id: string
          qty: number
          retailer_id: string | null
          sale_id: string | null
          salesman_id: string
          unit_price: number
        }
        Insert: {
          batch_no?: string | null
          cost_price?: number | null
          txn_date?: string
          created_at?: string
          id?: string
          imei?: string | null
          kind: Database["public"]["Enums"]["move_kind"]
          product_id: string
          qty: number
          retailer_id?: string | null
          sale_id?: string | null
          salesman_id: string
          unit_price?: number
        }
        Update: {
          batch_no?: string | null
          cost_price?: number | null
          txn_date?: string
          created_at?: string
          id?: string
          imei?: string | null
          kind?: Database["public"]["Enums"]["move_kind"]
          product_id?: string
          qty?: number
          retailer_id?: string | null
          sale_id?: string | null
          salesman_id?: string
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "stock_movements_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: false
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_sale_id_fkey"
            columns: ["sale_id"]
            isOneToOne: false
            referencedRelation: "sales"
            referencedColumns: ["id"]
          },
        ]
      }
      user_permission_overrides: {
        Row: {
          permissions: Json
          updated_at: string
          updated_by: string
          user_id: string
        }
        Insert: {
          permissions?: Json
          updated_at?: string
          updated_by: string
          user_id: string
        }
        Update: {
          permissions?: Json
          updated_at?: string
          updated_by?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_permission_overrides_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      user_roles: {
        Row: {
          id: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Insert: {
          id?: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Update: {
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          user_id?: string
        }
        Relationships: []
      }
      suppliers: {
        Row: { address: string | null; created_at: string; id: string; name: string; phone: string | null }
        Insert: { address?: string | null; created_at?: string; id?: string; name: string; phone?: string | null }
        Update: { address?: string | null; created_at?: string; id?: string; name?: string; phone?: string | null }
        Relationships: []
      }
      purchases: {
        Row: { client_op_id: string | null; created_at: string; created_by: string; doc_no: string | null; id: string; paid: number; supplier_id: string; total: number; txn_date: string }
        Insert: { client_op_id?: string | null; created_at?: string; created_by?: string; doc_no?: string | null; id?: string; paid?: number; supplier_id: string; total?: number; txn_date?: string }
        Update: { client_op_id?: string | null; created_at?: string; created_by?: string; doc_no?: string | null; id?: string; paid?: number; supplier_id?: string; total?: number; txn_date?: string }
        Relationships: []
      }
      supplier_payments: {
        Row: { amount: number; client_op_id: string | null; created_at: string; created_by: string; doc_no: string | null; id: string; method: string; note: string | null; supplier_id: string; txn_date: string }
        Insert: { amount: number; client_op_id?: string | null; created_at?: string; created_by?: string; doc_no?: string | null; id?: string; method?: string; note?: string | null; supplier_id: string; txn_date?: string }
        Update: { amount?: number; client_op_id?: string | null; created_at?: string; created_by?: string; doc_no?: string | null; id?: string; method?: string; note?: string | null; supplier_id?: string; txn_date?: string }
        Relationships: []
      }
      expenses: {
        Row: { amount: number; category: string; client_op_id: string | null; created_at: string; created_by: string; doc_no: string | null; id: string; note: string | null; txn_date: string }
        Insert: { amount: number; category: string; client_op_id?: string | null; created_at?: string; created_by?: string; doc_no?: string | null; id?: string; note?: string | null; txn_date?: string }
        Update: { amount?: number; category?: string; client_op_id?: string | null; created_at?: string; created_by?: string; doc_no?: string | null; id?: string; note?: string | null; txn_date?: string }
        Relationships: []
      }
      retailer_returns: {
        Row: { client_op_id: string | null; created_at: string; doc_no: string | null; id: string; retailer_id: string; sale_id: string | null; salesman_id: string; total: number; txn_date: string }
        Insert: { client_op_id?: string | null; created_at?: string; doc_no?: string | null; id?: string; retailer_id: string; sale_id?: string | null; salesman_id: string; total?: number; txn_date?: string }
        Update: { client_op_id?: string | null; created_at?: string; doc_no?: string | null; id?: string; retailer_id?: string; sale_id?: string | null; salesman_id?: string; total?: number; txn_date?: string }
        Relationships: []
      }
      business_profile: {
        Row: { address: string; id: boolean; name: string; phone: string; updated_at: string; updated_by: string | null }
        Insert: { address?: string; id?: boolean; name?: string; phone?: string; updated_at?: string; updated_by?: string | null }
        Update: { address?: string; id?: boolean; name?: string; phone?: string; updated_at?: string; updated_by?: string | null }
        Relationships: []
      }
      doc_counters: {
        Row: { kind: string; last_no: number; prefix: string }
        Insert: { kind: string; last_no?: number; prefix: string }
        Update: { kind?: string; last_no?: number; prefix?: string }
        Relationships: []
      }
      processed_ops: {
        Row: { actor: string; client_op_id: string; created_at: string; kind: string; result_ref: string | null }
        Insert: { actor: string; client_op_id: string; created_at?: string; kind: string; result_ref?: string | null }
        Update: { actor?: string; client_op_id?: string; created_at?: string; kind?: string; result_ref?: string | null }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      business_snapshot: { Args: never; Returns: Json }
      cancel_business_history: {
        Args: { _id: string; _reason: string; _table: string }
        Returns: undefined
      }
      check_imei: {
        Args: { _imei: string; _mode: string; _salesman: string }
        Returns: Json
      }
      dealer_risk_history: { Args: never; Returns: Json }
      distribution_dashboard: { Args: never; Returns: Json }
      distribution_insights: { Args: never; Returns: Json }
      distribution_stock_counts: { Args: never; Returns: Json }
      export_business_data: { Args: never; Returns: Json }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
      holding_qty: {
        Args: { _product: string; _salesman: string }
        Returns: number
      }
      issue_stock: {
        Args: { _items: Json; _salesman: string }
        Returns: undefined
      }
      manage_business_record: {
        Args: {
          _action: string
          _id: string
          _reason: string
          _table: string
          _values: Json
        }
        Returns: undefined
      }
      manage_user_access: {
        Args: {
          _active: boolean
          _confirmed: boolean
          _permissions: Json
          _reason: string
          _role: Database["public"]["Enums"]["app_role"]
          _user: string
        }
        Returns: undefined
      }
      record_sale: {
        Args: { _items: Json; _paid: number; _retailer: string }
        Returns: string
      }
      reset_business_data: {
        Args: { _backup_id: string; _confirmation: string }
        Returns: undefined
      }
      restore_business_data: {
        Args: { _backup_id: string; _confirmation: string; _snapshot: Json }
        Returns: undefined
      }
      return_stock: {
        Args: { _items: Json; _salesman: string }
        Returns: undefined
      }
      set_dealer_block: {
        Args: { _blocked: boolean; _confirmed: boolean; _retailer: string }
        Returns: undefined
      }
      user_can: {
        Args: { _permission: string; _user: string }
        Returns: boolean
      }
      next_doc_no: { Args: { _kind: string }; Returns: string }
      retailer_due: { Args: { _retailer: string }; Returns: number }
      salesman_cash: { Args: { _salesman: string }; Returns: number }
      supplier_due: { Args: { _supplier: string }; Returns: number }
      retailer_ledgers: { Args: Record<string, never>; Returns: Json }
      profit_summary: { Args: { _from: string; _to: string }; Returns: Json }
      record_retailer_payment: { Args: { _retailer: string; _amount: number; _method: string; _note: string | null; _date: string | null; _op: string | null }; Returns: string }
      record_deposit: { Args: { _salesman: string; _amount: number; _method: string; _note: string | null; _date: string | null; _op: string | null }; Returns: string }
      record_purchase: { Args: { _supplier: string; _items: Json; _paid: number; _date: string | null; _op: string | null }; Returns: string }
      record_supplier_payment: { Args: { _supplier: string; _amount: number; _method: string; _note: string | null; _date: string | null; _op: string | null }; Returns: string }
      record_expense: { Args: { _category: string; _amount: number; _note: string | null; _date: string | null; _op: string | null }; Returns: string }
      record_retailer_return: { Args: { _retailer: string; _items: Json; _date: string | null; _op: string | null }; Returns: string }
      receive_stock: { Args: { _product: string; _qty: number; _kind: string; _reason: string | null; _date: string | null; _op: string | null }; Returns: string }
      register_imeis: { Args: { _product: string; _imeis: string[]; _cost: number }; Returns: number }
      set_business_profile: { Args: { _name: string; _address: string; _phone: string }; Returns: undefined }
      user_is_active: { Args: { _user: string }; Returns: boolean }
    }
    Enums: {
      app_role: "admin" | "salesman"
      imei_status: "in_stock" | "with_salesman" | "sold" | "damaged"
      move_kind: "issue" | "sale" | "return" | "damage" | "purchase" | "opening" | "adjustment" | "sale_return"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      app_role: ["admin", "salesman"],
      imei_status: ["in_stock", "with_salesman", "sold", "damaged"],
      move_kind: ["issue", "sale", "return", "damage"],
    },
  },
} as const
