# Module: Bank

# Helper functions for bank account management
# Note: Not defined in lib because DB must already be init'ed.
module Bot::Bank
  include Constants
  include Convenience

  # The maximum number of days old a temp balance can be before it is dropped.
  # Note: Count starts from the past monday.
  MAX_BALANCE_AGE_DAYS = 28

  # The maximum number of days old a temp balance before it's considered in risk.
  # Note: Count starts from the past monday.
  MAX_BALANCE_AGE_SAFE_DAYS = MAX_BALANCE_AGE_DAYS - 7
  
  # Permanent user balances, one entry per user, negative => fines
  # { user_id, amount }
  USER_PERMA_BALANCES = DB[:econ_user_perma_balances]
  
  # User balances table, these balances expire on a rolling basis
  # { transaction_id, user_id, timestamp, amount }
  USER_BALANCES = DB[:econ_user_balances]

  # Path to crystal's data folder
  ECON_DATA_PATH = "#{Bot::DATA_PATH}/economy".freeze

  module_function

  # Check for and remove any and all expired balances.
  def CleanAccount(user_id)
    past_monday = Bot::Timezone::GetUserPastMonday(user_id)
    last_valid_timestamp = (past_monday - MAX_BALANCE_AGE_DAYS).to_time.to_i

    # remove all expired transaction
    user_transactions = USER_BALANCES.where{Sequel.&({user_id: user_id}, (timestamp < last_valid_timestamp))}
    user_transactions.delete
  end

  # Gets the user's current balance. Assumes database is clean.
  def GetBalance(user_id)
    sql = 
      "SELECT user_id, SUM(amount) total\n" +
      "FROM\n" + 
      "(\n" +
      "  SELECT user_id, amount FROM econ_user_balances\n" +
      "  WHERE user_id = #{user_id}\n" +
      "  UNION ALL\n" +
      "  SELECT user_id, amount FROM econ_user_perma_balances\n" +
      "  WHERE user_id = #{user_id}\n" +
      ") s\n" +
      "GROUP BY user_id;"

    balance = DB[sql]
    if(balance == nil || balance.first == nil)
      balance = 0
    else
      balance = balance.first[:total]
    end

    return balance
  end

  # Geths the amount of the user's balance that is at risk of expriring.
  def GetAtRiskBalance(user_id)
    past_monday = Bot::Timezone::GetUserPastMonday(user_id)
    last_safe_timestamp = (past_monday - MAX_BALANCE_AGE_SAFE_DAYS).to_time.to_i
    
    user_transactions = USER_BALANCES.where{Sequel.&({user_id: user_id}, (timestamp < last_safe_timestamp))}
    at_risk_balance = user_transactions.sum(:amount)
    return at_risk_balance != nil ? at_risk_balance : 0
  end

  # Gets the user's permanent balance.
  def GetPermaBalance(user_id)
    balance = USER_PERMA_BALANCES.where(user_id: user_id).sum(:amount)
    if(balance == nil)
      balance = 0
    end
    return balance
  end
  
  # Deposit money to perma if fines exist then to temp balances, cannot be negative!
  def Deposit(user_id, amount)
    if amount < 0
      return false
    end

    # pay off fines first if user has any
    perma_balance = USER_PERMA_BALANCES.where(user_id: user_id)
    if perma_balance.first != nil && perma_balance.first[:amount] < 0
      new_fine_balance = [0, perma_balance.first[:amount] + amount].min
      amount = [0, amount + perma_balance.first[:amount]].max

      perma_balance.update(amount: new_fine_balance)
    end

    # deposit remainder
    if amount > 0
      timestamp = Time.now.to_i
      USER_BALANCES << { user_id: user_id, timestamp: timestamp, amount: amount }
    end

    return true
  end

  # Deposit money to perma, can also be used for fines (negative)!
  def DepositPerma(user_id, amount)
    if USER_PERMA_BALANCES[user_id: user_id]
      perma_balance = USER_PERMA_BALANCES.where(user_id: user_id)
      perma_balance.update(amount: perma_balance.first[:amount] + amount)
    else
      USER_PERMA_BALANCES <<{ user_id: user_id, amount: amount }
    end

    return true
  end

  # Attempt to withdraw the specified amount, return success. Assumes database is clean.
  def Withdraw(user_id, amount)
    if GetBalance(user_id) < amount || amount < 0
      return false
    end

    # iterate through balances and remove until amount is withdrawn
    user_transactions = USER_BALANCES.where{Sequel.&({user_id: user_id}, (amount > 0))}.order(Sequel.asc(:timestamp))
    while amount > 0 and user_transactions.count > 0 do
      transaction = user_transactions.first
      transaction_id = transaction[:transaction_id]
      old_amount = transaction[:amount]
      if old_amount > amount
        old_amount -= amount
        user_transactions.where(transaction_id: transaction_id).update(amount: old_amount)
        amount = 0
      else
        amount -= old_amount
        user_transactions.where(transaction_id: transaction_id).delete
      end
    end

    # remove remaining balance from permanent balances
    if amount > 0
      user_entry = USER_PERMA_BALANCES.where(user_id: user_id)
      user_entry.update(amount: user_entry.first[:amount] - amount)
    end

    return true
  end

  # Appraise the value/cost of a given item or action.
  # Note: see ECON_DATA_PATH/point_values.yml
  def AppraiseItem(item_id)
    points_yaml = YAML.load_data!("#{ECON_DATA_PATH}/point_values.yml")
    return points_yaml[item_id]
  end
end