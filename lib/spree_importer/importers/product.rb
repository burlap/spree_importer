module SpreeImporter
  module Importers
    class Product
      include SpreeImporter::Importers::Base

      attr_accessor :batch_id

      row_based

      import_attributes :sku_pattern, :sku, :name, :price, :available_on,
                        :description, :meta_description, :meta_keywords, :cost_price

      target ::Spree::Product

      def import(headers, csv)
        previous ||= {}
        each_instance headers, csv do |product, row|
          master_sku             = val headers, row, :master_sku
          product.sku            = master_sku unless master_sku.nil?
          product.sku_pattern  ||= SpreeImporter.config.default_sku

          product.batch_id        = batch_id

          tax = val headers, row, :tax
          meta_keywords_en = val headers, row, :enmetakeywords
          #meta_description_en = val headers, row, :enmetadescription
          name_en = val headers, row, :enname
          name_ru = val headers, row, :runame
          description_en = val headers, row, :endescription
          description_ru = val headers, row, :rudescription
          relation = val headers, row, :relations
          rel_type = val headers, row, :relationtype


          # for safety we're skipping and warning on products that look like dups
          if ::Spree::Variant.exists? sku: product.sku
            # self.warnings << "Product exists for sku #{product.sku}, skipping product import"
            next
          end

          category    = Field.new(val(headers, row, :category)).sanitized
          shipping    = val headers, row, :shipping

          if shipping.nil?
            shipping = ::Spree::ShippingCategory.find_by_name "Default"
          else
            shipping = ::Spree::ShippingCategory.find_by_name shipping
          end
          product.shipping_category_id = shipping.id
          product.tax_category_id = tax

          #previously it was before shipping category.
          setup_taxonomies(product, row['category'])

          properties                   = [ ]
          properties, option_types     = props_and_ops_from_headers headers, row

          product.option_types = option_types

          setup_variants product,   option_types, headers, row
          setup_properties product, properties, headers, row

          image = val headers, row, :photo
          unless image.blank?
            setup_images product, image
          end

          product.set_translations(
            :en => {:name => name_en, :description => description_en, :meta_keywords => meta_keywords_en}
            :ru => {:name => name_ru, :description => description_ru}
            )

          product.save!
          if (previous.present? && previous.sku == relation)
            setup_relations product, previous, rel_type
          elsif (relation.present?)
            previous = Spree::Product.find_by_sku(relation)
            relation_set product, previous, rel_type
          end
          previous = product
        end
      end

      def setup_taxonomies(product, taxonomies)
        if taxonomies
          taxon_names = taxonomies.split(SpreeImporter.config.delimiter).map do |tax|
            tax.split(SpreeImporter.config.taxon_separator).last.strip
          end.uniq
          Spree::Taxon.where(name: taxon_names).each do |t|
            t.products << product
          end
        end
      end

      def setup_properties(product, properties, headers, row)
        properties.each do |prop|
          value = val headers, row, prop.name
          if value
            product.set_property prop.name, value
          end
        end
      end

      def setup_variants(product, option_types, headers, row)
        option_values_hash = { }

        option_types.each do |ot|
          if field = val(headers, row, ot.name)
            fields                    = field.split(SpreeImporter.config.delimiter).map{|f| Field.new(f) }
            field_values              = (fields.map(&:key) + fields.map(&:label)).compact.uniq
            option_values_hash[ot.id] = ot.option_values.where(name: field_values).pluck(:id).uniq
          end
        end

        if option_values_hash.any?
          product.option_values_hash  = option_values_hash
        end
        p "Option values hash #{product.option_values_hash}"
        product.save!
        if val headers, row, :sku
          product.variants.destroy_all
        else
          product.variants.each &:generate_sku!
        end

        product.variants.each  do |v|
          v.update_attribute :batch_id, batch_id
          v.update_attribute :tax_category_id, product.tax_category_id
        end
        product.master.update_attribute :tax_category_id, product.tax_category_id
        product.master.update_attribute :batch_id, batch_id
      end

      def setup_images(product, image)
        images = image.split(SpreeImporter.config.delimiter).map{|f| Field.new(f) }

        images.each do |photo|
          Spree::Image.create(:viewable_type => "Spree::Variant", :viewable_id => product.master.id, :attachment => File.open("/Users/burlap/Documents/dental/photos/#{photo}"), :alt => product.name)
        end

      end

      def setup_relations(product, previous, rel_type)

        previous.relations.each do |related|
          # # product -> relation
          # relation_params = {relation_type_id: 1, relatable_id: product.id, relatable_type: "Spree::Product", related_to_id: related.related_to.id, related_to_type: "Spree::Product", discount_amount: 0, position: nil}
          # relation = product.relations.new(relation_params)
          # relation.relatable = product
          # relation.related_to = related.related_to
          # relation.save!

          # # relation -> product
          # relation_params = {relation_type_id: 1, relatable_id: related.related_to.id, relatable_type: "Spree::Product", related_to_id: product.id, related_to_type: "Spree::Product", discount_amount: 0, position: nil}
          # relation = product.relations.new(relation_params)
          # relation.relatable = related.related_to
          # relation.related_to = product
          # relation.save!
          relation_set product, related, rel_type
        end

        ## product -> previous
        # relation_params = {relation_type_id: 1, relatable_id: product.id, relatable_type: "Spree::Product", related_to_id: previous.id, related_to_type: "Spree::Product", discount_amount: 0, position: nil}
        # relation = product.relations.new(relation_params)
        # relation.relatable = product
        # relation.related_to = previous
        # relation.save!
        # ## previous -> product
        # relation_params = {relation_type_id: 1, relatable_id: previous.id, relatable_type: "Spree::Product", related_to_id: product.id, related_to_type: "Spree::Product", discount_amount: 0, position: nil}
        # relation = product.relations.new(relation_params)
        # relation.relatable = previous
        # relation.related_to = product
        # relation.save!
        relation_set product, previous, rel_type

      end

      def relation_set(product_a, product_b, rel_type)
        ## product A -> product B
        relation_params = {relation_type_id: rel_type, relatable_id: product_a.id, relatable_type: "Spree::Product", related_to_id: product_b.id, related_to_type: "Spree::Product", discount_amount: 0, position: nil}
        relation = product_a.relations.new(relation_params)
        relation.relatable = product_a
        relation.related_to = product_b
        relation.save!
        ## product B -> product A
        relation_params = {relation_type_id: rel_type, relatable_id: product_b.id, relatable_type: "Spree::Product", related_to_id: product_a.id, related_to_type: "Spree::Product", discount_amount: 0, position: nil}
        relation = product_b.relations.new(relation_params)
        relation.relatable = product_b
        relation.related_to = product_a
        relation.save!
      end

    end

  end
end
