require 'json'

module BankScrap
  class Bbva < Bank
    BASE_ENDPOINT     = 'https://servicios.bbva.es'
    LOGIN_ENDPOINT    = '/DFAUTH/slod/DFServletXML'
    PRODUCTS_ENDPOINT = '/ENPP/enpp_mult_web_mobility_02/products/v1'
    ACCOUNT_ENDPOINT  = '/ENPP/enpp_mult_web_mobility_02/accounts/'
    # BBVA expects an identifier before the actual User Agent, but 12345 works fine
    USER_AGENT        = '12345;Android;LGE;Nexus 5;1080x1776;Android;5.1.1;BMES;4.4;xxhd'

    def initialize(user, password, log: false, debug: false, extra_args: nil)
      @user = format_user(user.dup)
      @password = password
      @log = log
      @debug = debug

      initialize_connection

      add_headers(
        'User-Agent'       => USER_AGENT,
        'BBVA-User-Agent'  => USER_AGENT,
        'Accept-Language'  => 'spa',
        'Content-Language' => 'spa',
        'Accept'           => 'application/json',
        'Accept-Charset'   => 'UTF-8',
        'Connection'       => 'Keep-Alive',
        'Host'             => 'bancamovil.grupobbva.com',
        'Cookie2'          => '$Version=1'
      )

      login
      super
    end

    # Fetch all the accounts for the given user
    # Returns an array of BankScrap::Account objects
    def fetch_accounts
      log 'fetch_accounts'

      # Even if the required method is an HTTP POST
      # the API requires a funny header that says is a GET
      # otherwise the request doesn't work.
      response = with_headers('BBVA-Method' => 'GET') do
        post(BASE_ENDPOINT + PRODUCTS_ENDPOINT)
      end

      json = JSON.parse(response)
      json['accounts'].map { |data| build_account(data) }
    end

    # Fetch transactions for the given account.
    # By default it fetches transactions for the last month,
    # The maximum allowed by the BBVA API is the last 3 years.
    #
    # Account should be a BankScrap::Account object
    # Returns an array of BankScrap::Transaction objects
    def fetch_transactions_for(account, start_date: Date.today - 1.month, end_date: Date.today)
      from_date = start_date.strftime('%Y-%m-%d')

      # Misteriously we need a specific content-type here
      funny_headers = {
        'Content-Type' => 'application/json; charset=UTF-8',
        'BBVA-Method' => 'GET'
      }

      # The API accepts a toDate param that we could pass the end_date argument,
      # however when we pass the toDate param, the API stops returning the account balance.
      # Therefore we need to take a workaround: only filter with fromDate and loop
      # over all the available pages, filtering out the movements that doesn't match
      # the end_date argument.
      url = BASE_ENDPOINT +
            ACCOUNT_ENDPOINT +
            account.id +
            "/movements/v1?fromDate=#{from_date}"

      offset = nil
      pagination_balance = nil
      transactions = []

      with_headers(funny_headers) do
        # Loop over pagination
        loop do
          new_url = offset ? (url + "&offset=#{offset}") : url
          new_url = pagination_balance ? (new_url + "&paginationBalance=#{pagination_balance}") : new_url
          json = JSON.parse(post(new_url))

          unless json['movements'].blank?
            # As explained before, we have to discard records newer than end_date.
            filtered_movements = json['movements'].select { |m| Date.parse(m['operationDate']) <= end_date }

            transactions += filtered_movements.map do |data|
              build_transaction(data, account)
            end
            offset = json['offset']
            pagination_balance = json['paginationBalance']
          end

          break unless json['thereAreMoreMovements'] == true
        end
      end

      transactions
    end

    private

    # As far as we know there are two types of identifiers BBVA uses
    # 1) A number of 7 characters that gets passed to the API as it is
    # 2) A DNI number, this needs to transformed before it get passed to the API
    #    Example: "49021740T" will become "0019-049021740T"
    def format_user(user)
      user.upcase!

      if user.match(/^[0-9]{8}[A-Z]$/)
        # It's a DNI
        "0019-0#{user}"
      else
        user
      end
    end

    def login
      log 'login'
      params = {
        'origen'         => 'enpp',
        'eai_tipoCP'     => 'up',
        'eai_user'       => @user,
        'eai_password'   => @password
      }
      post(BASE_ENDPOINT + LOGIN_ENDPOINT, fields: params)
    end

    # Build an Account object from API data
    def build_account(data)
      Account.new(
        bank: self,
        id: data['id'],
        name: data['name'],
        available_balance: data['availableBalance'],
        balance: data['availableBalance'],
        currency: data['currency'],
        iban: data['iban'],
        description: "#{data['typeDescription']} #{data['familyCode']}"
      )
    end

    # Build a transaction object from API data
    def build_transaction(data, account)
      Transaction.new(
        account: account,
        id: data['id'],
        amount: transaction_amount(data),
        description: data['conceptDescription'] || data['description'],
        effective_date: Date.strptime(data['operationDate'], '%Y-%m-%d'),
        currency: data['currency'],
        balance: transaction_balance(data)
      )
    end

    def transaction_amount(data)
      Money.new(data['amount'] * 100, data['currency'])
    end

    def transaction_balance(data)
      return unless data['accountBalanceAfterMovement']
      Money.new(data['accountBalanceAfterMovement'] * 100, data['currency'])
    end
  end
end
