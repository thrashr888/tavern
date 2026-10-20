#!/usr/bin/env python3
"""Writes made-up transcripts for Ivy, a demo agent whose cider tool calls come back as MCP Apps
cards: `cards.py <out-dir>` writes ivy-day.json (weather and agenda) and ivy-home.json (Home).
Dates are relative to now so the cards read "Today"; nothing comes from this Mac."""
import json, sys, time
from datetime import datetime, timedelta, timezone

out = sys.argv[1]
now = datetime.now().astimezone()
utc = timezone.utc
today = now.replace(hour=0, minute=0, second=0, microsecond=0)
ms = lambda d: int(d.timestamp() * 1000)

def transcript(turns):
    entries, t = [], now - timedelta(minutes=6)
    for i, (role, content, extra) in enumerate(turns):
        message = {"role": role, "content": content, **extra}
        entries.append({"id": f"i{i + 1}", "timestamp": ms(t), "message": message})
        t += timedelta(seconds=20)
    return entries

def call(i, name, args):
    return {"type": "toolCall", "id": i, "name": f"cider__{name}", "arguments": args}

def result(i, name, uri, data):
    structured = {"ok": True, "data": data}
    return ("toolResult", [{"type": "text", "text": json.dumps(structured)}],
            {"toolCallId": i, "toolName": f"cider__{name}", "isError": False,
             "details": {"mcp": {"server": "cider", "tool": name},
                         "ui": {"server": "cider", "resourceUri": uri, "structuredContent": structured}}})

conditions = ["partlyCloudy", "mostlyCloudy", "rain", "showers", "mostlyClear", "clear", "partlyCloudy"]
days = [{"date": (today + timedelta(days=d)).strftime("%Y-%m-%d"), "condition": c,
         "high_c": [17, 15, 13, 14, 18, 20, 19][d], "low_c": [9, 10, 9, 8, 9, 11, 12][d],
         "precipitation_chance": [10, 30, 80, 60, 5, 0, 10][d]} for d, c in enumerate(conditions)]
hour0 = now.replace(minute=0, second=0, microsecond=0)
hourly = [{"time": (hour0 + timedelta(hours=h)).isoformat(), "condition": "partlyCloudy" if h < 6 else "mostlyCloudy",
           "temperature_c": round(16 - abs(h - 2) * 0.6, 1), "precipitation_chance": 10 if h < 8 else 30} for h in range(12)]
weather = {"days": days, "hourly_next_24": hourly, "location": {"lat": 45.52, "lon": -122.68, "source": "args"},
           "attribution": {"service_name": "Apple Weather", "legal_url": "https://weatherkit.apple.com/legal-attribution.html",
                           "logo_dark_url": "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_wht_en_3X_090122.png",
                           "logo_light_url": "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_blk_en_3X_090122.png"}}

def event(title, cal, start_h, end_h, location=None):
    start, end = today + timedelta(hours=start_h), today + timedelta(hours=end_h)
    e = {"id": title, "title": title, "calendar": cal, "is_all_day": False, "has_attendees": True, "has_recurrences": False,
         "attendee_count": 3, "alarm_count": 1,
         "start_date": start.astimezone(utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "end_date": end.astimezone(utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if location: e["location"] = location
    return e
agenda = [event("Guild standup", "Work", 9.5, 9.75, "Zoom"), event("Pricing page review", "Work", 11, 11.5),
          event("Lunch with Lark", "Personal", 12.5, 13.5, "Pine Street Market"), event("Release notes due", "Work", 16, 16.5),
          {"id": "trip", "title": "Coast trip", "calendar": "Family", "is_all_day": True, "has_attendees": False, "has_recurrences": False,
           "attendee_count": 0, "alarm_count": 0, "start_date": (today + timedelta(days=1)).strftime("%Y-%m-%d"),
           "end_date": (today + timedelta(days=2)).strftime("%Y-%m-%d")}]

day = transcript([
    ("user", "What does my day look like?", {}),
    ("assistant", [{"type": "text", "text": "Checking the forecast and your calendar."},
                   call("w1", "weather_forecast", {"days": 7}), call("c1", "calendar_list", {"days_back": 0, "days_ahead": 1})], {}),
    result("w1", "weather_forecast", "ui://cider/weather", weather),
    result("c1", "calendar_list", "ui://cider/agenda", agenda),
    ("assistant", [{"type": "text", "text": "Dry and mild today, highs around 17°. Rain moves in Wednesday, so the coast trip tomorrow looks good. "
                    "Four things on the calendar: standup at 9:30, the pricing review at 11, lunch with Lark, and release notes are due at 4."}], {}),
])

def light(i, name, room, on, brightness=None):
    v = {"power_state": on}
    if brightness is not None: v["brightness"] = brightness
    return {"id": f"a{i}", "name": name, "room": room, "type": "lightbulb", "service": name, "values": v,
            "writable": ["power_state", "brightness"]}
home = {"accessories": [
    light(1, "Ceiling", "Living Room", True, 80), light(2, "Reading lamp", "Living Room", True, 45),
    {"id": "a3", "name": "Thermostat", "room": "Living Room", "type": "thermostat", "service": "Thermostat",
     "values": {"current_temperature": 20.5, "target_temperature": 21}, "writable": ["target_temperature"]},
    light(4, "Pendants", "Kitchen", False), {"id": "a5", "name": "Coffee", "room": "Kitchen", "type": "outlet", "service": "Coffee",
     "values": {"power_state": False}, "writable": ["power_state"]},
    {"id": "a6", "name": "Front door", "room": "Entry", "type": "lock_mechanism", "service": "Front door",
     "values": {"lock_current_state": 1}, "writable": ["lock_target_state"]},
    light(7, "Porch", "Entry", True, 100)],
    "scenes": [{"id": "s1", "name": "Good morning"}, {"id": "s2", "name": "Movie night"}, {"id": "s3", "name": "Leaving home"}]}
home_t = transcript([
    ("user", "Which lights are on?", {}),
    ("assistant", [call("h1", "home_status", {})], {}),
    result("h1", "home_status", "ui://cider/home", home),
    ("assistant", [{"type": "text", "text": "Three lights are on: the living room ceiling and reading lamp, and the porch. The front door is locked. "
                    "Tap a light to switch it, or run a scene; I'll check with you first."}], {}),
])
json.dump(day, open(f"{out}/ivy-day.json", "w"), indent=1)
json.dump(home_t, open(f"{out}/ivy-home.json", "w"), indent=1)
