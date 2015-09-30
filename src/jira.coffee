# Description:
#  Quickly file JIRA tickets with hubot
#  Also listens for mention of tickets and responds with information
#
# Dependencies:
# - moment
# - octokat
# - node-fetch
#
# Configuration:
#   HUBOT_JIRA_URL (format: "https://jira-domain.com:9090")
#   HUBOT_JIRA_USERNAME
#   HUBOT_JIRA_PASSWORD
#   HUBOT_JIRA_PROJECTS_MAP (format: "{\"web\":\"WEB\",\"android\":\"AN\",\"ios\":\"IOS\",\"platform\":\"PLAT\"}"
#   HUBOT_GITHUB_TOKEN - Github Application Token
#
# Commands:
#   hubot bug - File a bug in JIRA corresponding to the project of the channel
#   hubot task - File a task in JIRA corresponding to the project of the channel
#   hubot story - File a story in JIRA corresponding to the project of the channel
#
# Author:
#   ndaversa


module.exports = (robot) ->
  jiraUrl = process.env.HUBOT_JIRA_URL
  jiraUsername = process.env.HUBOT_JIRA_USERNAME
  jiraPassword = process.env.HUBOT_JIRA_PASSWORD
  projects = JSON.parse process.env.HUBOT_JIRA_PROJECTS_MAP
  token = process.env.HUBOT_GITHUB_TOKEN

  fetch = require 'node-fetch'
  moment = require 'moment'
  Octokat = require 'octokat'
  octo = new Octokat token: token

  prefixes = (key for team, key of projects).reduce (x,y) -> x + "-|" + y
  jiraPattern = eval "/(^|\\s)(" + prefixes + "-)(\\d+)\\b/gi"
  headers =
      "Content-Type": "application/json"
      "Authorization": 'Basic ' + new Buffer("#{jiraUsername}:#{jiraPassword}").toString('base64')

  parseJSON = (response) ->
    return response.json()

  checkStatus = (response) ->
    if response.status >= 200 and response.status < 300
      return response
    else
      error = new Error(response.statusText)
      error.response = response
      throw error

  report = (project, type, msg) ->
    reporter = null

    fetch("#{jiraUrl}/rest/api/2/user/search?username=#{msg.message.user.email_address}", headers: headers)
    .then (res) ->
      console.log "checking"
      checkStatus res
    .then (res) ->
      console.log "parsing"
      parseJSON res
    .then (user) ->
      reporter = user[0] if user and user.length is 1
      quoteRegex = /`{1,3}([^]*?)`{1,3}/
      labelsRegex = /#\S+\s?/g
      labels = ["triage"]
      message = msg.match[1]

      desc = message.match(quoteRegex)[1] if quoteRegex.test(message)
      message = message.replace(quoteRegex, "") if desc

      if labelsRegex.test(message)
        labels = (message.match(labelsRegex).map((label) -> label.replace('#', '').trim())).concat(labels)
        message = message.replace(labelsRegex, "")

      issue =
        fields:
          project:
            key: project
          summary: message
          labels: labels
          description: """
            #{(if desc then desc + "\n\n" else "")}
            Reported by #{msg.message.user.name} in ##{msg.message.room} on #{robot.adapterName}
            https://#{robot.adapter.client.team.domain}.slack.com/archives/#{msg.message.room}/p#{msg.message.id.replace '.', ''}
          """
          issuetype:
            name: type

      issue.fields.reporter = reporter if reporter
      issue
    .then (issue) ->
      console.log "fetching issue", issue
      fetch "#{jiraUrl}/rest/api/2/issue",
        headers: headers
        method: "POST"
        body: JSON.stringify issue
    .then (res) ->
      console.log "checking", res
      checkStatus res
    .then (res) ->
      console.log "parsing"
      parseJSON res
    .then (json) ->
      msg.send "<@#{msg.message.user.id}> Ticket created: #{jiraUrl}/browse/#{json.key}"
    .catch (error) ->
      msg.send "<@#{msg.message.user.id}> Unable to create ticket #{error}"

  robot.respond /story ([^]+)/i, (msg) ->
    room = msg.message.room
    project = projects[room]
    return msg.reply "Stories must be submitted in one of the following project channels:" + (" <\##{team}>" for team, key of projects) if not project
    report project, "Story / Feature", msg

  robot.respond /bug ([^]+)/i, (msg) ->
    room = msg.message.room
    project = projects[room]
    return msg.reply "Bugs must be submitted in one of the following project channels:" + (" <\##{team}>" for team, key of projects) if not project
    report project, "Bug", msg

  robot.respond /task ([^]+)/i, (msg) ->
    room = msg.message.room
    project = projects[room]
    return msg.reply "Tasks must be submitted in one of the following project channels:" + (" <\##{team}>" for team, key of projects) if not project
    report project, "Task", msg

  robot.hear jiraPattern, (msg) ->
    message = ""
    for issue in msg.match
      fetch("#{jiraUrl}/rest/api/2/issue/#{issue.trim().toUpperCase()}", headers: headers)
      .then (res) ->
        checkStatus res
      .then (res) ->
        parseJSON res
      .then (json) ->
        message = """
          *[#{json.key}] - #{json.fields.summary}*
          Status: #{json.fields.status.name}
          Assignee: #{if json.fields.assignee?.displayName then "<@#{json.fields.assignee.displayName}>" else "Unassigned"}
          Reporter: #{json.fields.reporter.displayName}
          JIRA: #{jiraUrl}/browse/#{json.key}
        """
        json
      .then (json) ->
        fetch("#{jiraUrl}/rest/dev-status/1.0/issue/detail?issueId=#{json.id}&applicationType=github&dataType=branch", headers: headers)
      .then (res) ->
        checkStatus res
      .then (res) ->
        parseJSON res
      .then (json) ->
        if json.detail?[0]?.pullRequests
          return Promise.all json.detail[0].pullRequests.map (pr) ->
            if pr.status is "OPEN"
              orgAndRepo = pr.destination.url.split("github.com")[1].split('tree')[0].split('/')
              repo = octo.repos(orgAndRepo[1], orgAndRepo[2])
              return repo.pulls(pr.id.replace('#', '')).fetch()
      .then (prs)->
        for pr in prs when pr
          message += """\n
            *[#{pr.title}]* +#{pr.additions} -#{pr.deletions}
            #{pr.htmlUrl}
            Updated: *#{moment(pr.updatedAt).fromNow()}*
            Status: #{if pr.mergeable then "Ready for merge" else "Needs rebase"}
            Assignee: #{ if pr.assignee? then "<@#{pr.assignee.login}>" else "Unassigned" }
          """
      .then () ->
        msg.send message
      .catch (error) ->
        msg.send "*[Error]* #{error}"
