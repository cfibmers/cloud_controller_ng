Sequel.migration do
  up do
    if supports_table_listing?
      tables.each do |table|
        schema(table).each do |column|
          if column[0].eql?(:salt)
            alter_table(table) do
              add_column :key_label, String
            end
          end
        end
      end
    end
  end

  down do
    if supports_table_listing?
      tables.each do |table|
        if table.columns.include?(:key_label)
          alter_table(table) do
            drop_column :key_label
          end
        end
      end
    end
  end
end