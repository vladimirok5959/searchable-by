require 'active_record'
require 'shellwords'

module ActiveRecord
  module SearchableBy
    class Column
      attr_reader :attr, :type
      attr_accessor :node

      def initialize(attr, type: :string)
        @attr = attr
        @type = type.to_sym
      end
    end

    class Config
      attr_reader :columns, :scoping
      attr_accessor :max_terms

      def initialize
        @columns = []
        @max_terms = 5
        scope { all }
      end

      def initialize_copy(other)
        @columns = other.columns.dup
        super
      end

      def column(*attrs, &block)
        opts = attrs.extract_options!
        attrs.each do |attr|
          columns.push Column.new(attr, opts)
        end
        columns.push Column.new(block, opts) if block
        columns
      end

      def scope(&block)
        @scoping = block
      end
    end

    def self.norm_values(query)
      values = Shellwords.split(query.to_s)
      values.flatten!
      values.reject!(&:blank?)
      values.uniq!
      values
    end

    def self.build_clauses(columns, values)
      clauses = values.map do |value|
        negate = value[0] == '-'
        value.slice!(0) if negate || value[0] == '+'

        grouping = columns.map do |column|
          build_condition(column, value)
        end
        grouping.compact!
        next if grouping.empty?

        clause = grouping.inject(&:or)
        clause = clause.not if negate
        clause
      end
      clauses.compact!
      clauses
    end

    def self.build_condition(column, value)
      case column.type
      when :int, :integer
        begin
          column.node.eq(Integer(value))
        rescue ArgumentError
          nil
        end
      else
        value = value.dup
        value.gsub!('%', '\%')
        value.gsub!('_', '\_')
        column.node.matches("%#{value}%")
      end
    end

    module ClassMethods
      def self.extended(base) # :nodoc:
        base.class_attribute :_searchable_by_config, instance_accessor: false, instance_predicate: false
        base._searchable_by_config = Config.new
        super
      end

      def inherited(base) # :nodoc:
        base._searchable_by_config = _searchable_by_config.dup
        super
      end

      def searchable_by(max_terms: 5, &block)
        _searchable_by_config.instance_eval(&block)
        _searchable_by_config.max_terms = max_terms if max_terms
      end

      # @param [String] query the search query
      # @return [ActiveRecord::Relation] the scoped relation
      def search_by(query)
        columns = _searchable_by_config.columns
        return all if columns.empty?

        values = SearchableBy.norm_values(query).first(_searchable_by_config.max_terms)
        return all if values.empty?

        columns.each do |col|
          col.node ||= col.attr.is_a?(Proc) ? col.attr.call : arel_table[col.attr]
        end
        clauses = SearchableBy.build_clauses(columns, values)
        return all if clauses.empty?

        scope = instance_exec(&_searchable_by_config.scoping)
        clauses.each do |clause|
          scope = scope.where(clause)
        end
        scope
      end
    end
  end

  class Base
    extend SearchableBy::ClassMethods
  end
end
