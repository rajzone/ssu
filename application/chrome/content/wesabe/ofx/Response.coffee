{trim}   = require 'lang/string'
Status   = require 'ofx/Status'
Document = require 'ofx/Document'
Account  = require 'ofx/Account'
privacy  = require 'util/privacy'

{tryThrow, tryCatch} = require 'util/try'

# Response - parse an OFX response message for needed information

# Takes the raw text of an OFX response of any supported kind (account info,
# bank statement, or credit card statement) and parses it just enough to
# extract information a client would need from it.  The Response object
# can be used to check for OFX errors in the response message, to get a list
# of bank and credit card accounts listed in the response, and to get a
# "sanitized" version of the response that masks any account numbers and
# removes other sensitive information (particularly, INTU tags that may
# reveal the user's bank username or other credentials) from the response
# text.
#
# Note that one OFX response file may contain multiple status responses,
# and some may be successful while others are not.  Response provides
# one isSuccess() method that checks *all* status blocks for any errors,
# and returns false if any errors exist.  You can retrieve all of the
# Status objects for this response in the Response.statuses array.
#
# Usage:
#
# //....build OFX account info request....
# var acctinfo_text = ofx_client.send_request(acctinfo_request);
# var acctinfo = new Response(acctinfo_text);
# if (acctinfo.isSuccess()) {
#     for (var i = 0; i < acctinfo.bankAccounts.length; i++) {
#         // ....build OFX bank statement request....
#         var statement_text = ofx_client.send_request(bankstmt_request);
#         var statement = new Response(statement_text);
#         if (statement.isSuccess()) {
#             wesabe_client.upload_statement(statement.get_sanitized_statement());
#         } else {
#             // report error
#         }
#     }
#
#     for (var i = 0; i < acctinfo.creditcardAccounts.length; i++) {
#         // ....build OFX bank statement request....
#         var statement_text = ofx_client.send_request(creditcardstmt_request);
#         var statement = new Response(statement_text);
#         if (statement.isSuccess()) {
#             wesabe_client.upload_statement(statement.get_sanitized_statement());
#         } else {
#             // report error
#         }
#     }
# } else {
#     // report error
# }

class Response
  constructor: (@response, @job) ->
    logger.radioactive 'ofx.Response: response=', @response
    @_find_statuses()

  # Public methods

  # Response OFX presented as a DOM tree.
  @::__defineGetter__ 'responseXML', ->
    @__responseXML__ ||= new Document @response, /BANKTRANLIST/i

  # Response OFX presented as a complete DOM tree, including BANKTRANLIST nodes.
  parseFullResponseXML: ->
    @__fullResponseXML__ ||= new Document @response

  # List of all deposit accounts.
  @::__defineGetter__ 'bankAccounts', ->
    @_find_accounts() unless @__bankAccounts__
    return @__bankAccounts__

  # List of all credit accounts.
  this::__defineGetter__ 'creditcardAccounts', ->
    @_find_accounts() unless @__creditcardAccounts__
    return @__creditcardAccounts__

  # List of all investment accounts.
  this::__defineGetter__ 'investmentAccounts', ->
    @_find_accounts() unless @__investmentAccounts__
    return @__investmentAccounts__

  hasOFX: ->
    @responseXML.documentElement?.tagName.toLowerCase() is 'ofx'

  # Check to see if the server returned any errors in the OFX response.
  isSuccess: ->
    @hasOFX() and not @_firstErrorStatus()

  isError: ->
    not @isSuccess()

  isGeneralError: ->
    @_firstErrorStatus()?.isGeneralError()

  isAuthenticationError: ->
    @_firstErrorStatus()?.isAuthenticationError()

  isAuthorizationError: ->
    @_firstErrorStatus()?.isAuthorizationError()

  # Get a list of Account objects representing bank
  # accounts found anywhere in this response.
  get_bank_accounts: ->
    @bankAccounts

  # Get a list of Account objects representing credit card
  # accounts found anywhere in this response.
  get_creditcard_accounts: ->
    @creditcardAccounts

  # Remove everything from this response that should never hit
  # the server -- account numbers, usernames, Intuit tags.
  getSanitizedResponse: ->
    sanitized_text = @response

    for {acctid, masked_acctid} in @bankAccounts.concat(@creditcardAccounts)
      sanitized_text = sanitized_text.replace(acctid, masked_acctid)

    intu_pattern = /<INTU.[^>]*>[^<]*(?:<\/INTU.[^>]*>[^<]*)?/ig
    while result = intu_pattern.exec(@response) and intu_tag = result[0]
      sanitized_text = sanitized_text.replace intu_tag, ""

    return sanitized_text

  # Private methods

  _firstErrorStatus: ->
    return null unless @statuses

    for status in @statuses
      return status if status.isError()

    return null

  _find_accounts: ->
    bank = @__bankAccounts__ = []
    credit = @__creditcardAccounts__ = []
    investment = @__investmentAccounts__ = []

    for acct in @responseXML.getElementsByTagName 'ACCTINFO'
      logger.radioactive acct
      [acctid]   = acct.getElementsByTagName 'ACCTID'
      [bankid]   = acct.getElementsByTagName 'BANKID'
      [accttype] = acct.getElementsByTagName 'ACCTTYPE'
      [desc]     = acct.getElementsByTagName 'DESC'
      [account]  = acct.getElementsByTagName 'CREDITCARD'

      acctid   = trim acctid.text if acctid
      accttype = trim accttype.text if accttype
      bankid   = trim bankid.text if bankid
      desc     = trim desc.text if desc
      account  = trim account.text if account

      if acct.getElementsByTagName('BANKACCTFROM').length
        bank.push new Account(accttype, acctid, bankid, desc)
      else if acct.getElementsByTagName('CCACCTFROM').length
        credit.push new Account("CREDITCARD", acctid, null, desc)
      else if acct.getElementsByTagName('INVACCTFROM').length
        investment.push new Account("INVESTMENT", acctid, null, desc)
      else
        logger.warn "Skipping unknown account type: ", acct

  _find_statuses: ->
    tryThrow 'Response#_find_statuses', =>
      @statuses = for status in @responseXML.getElementsByTagName 'STATUS'
                    logger.radioactive status
                    [code]      = status.getElementsByTagName 'CODE'
                    [severity]  = status.getElementsByTagName 'SEVERITY'
                    [message]   = status.getElementsByTagName 'MESSAGE'

                    code     = trim code.text if code
                    severity = trim severity.text if severity
                    message  = trim message.text if message

                    new Status code, severity, message


module.exports = Response
