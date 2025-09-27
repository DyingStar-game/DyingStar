extends Node

signal received_message(topic, message)
signal broker_connected()
signal broker_disconnected()
signal broker_connection_failed()
signal publish_acknowledge(pid)

var messages = {
	"sdo/register": [],
	"sdo/serverslist": [],
	"sdo/serverschanges": [],
	"sdo/servertooheavy": [],
	"sdo/players_list": [],
	"sdo/playerschanges": [],
}

var subscribed = {}

func connect_to_broker(_type, _url, _port):
	pass

func subscribe(topic):
	subscribed[topic] = true

func unsubscribe(topic):
	subscribed.erase(topic)

func publish(topic, message):
	messages[topic].append(message)
