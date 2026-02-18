local DoiteBuffData = {
  -- this uses spellId as key to avoid having to look up UNIT_CASTEVENT spell names

  -- list spells here that modify OTHER buff stacks.  Gaining stacks for the same spell is already handled
  -- Be sure to include a duration to use if the spell adds/creates/refreshes another buff
  stackModifiers = {
    -- Mage --
    [11366] = { -- Pyroblast rk 1
      modifiedBuffName = "Hot Streak",
      stackChange = -5
    },
    [12505] = {  -- Pyroblast rk 2
      modifiedBuffName = "Hot Streak",
      stackChange = -5
    },
    [12522] = {  -- Pyroblast rk 3
      modifiedBuffName = "Hot Streak",
      stackChange = -5
    },
    [12523] = {  -- Pyroblast rk 4
      modifiedBuffName = "Hot Streak",
      stackChange = -5
    },
    [12524] = {  -- Pyroblast rk 5
      modifiedBuffName = "Hot Streak",
      stackChange = -5
    },
    [12525] = {  -- Pyroblast rk 6
      modifiedBuffName = "Hot Streak",
      stackChange = -5
    },
    [12526] = {  -- Pyroblast rk 7
      modifiedBuffName = "Hot Streak",
      stackChange = -5
    },
    [18809] = {  -- Pyroblast rk 8
      modifiedBuffName = "Hot Streak",
      stackChange = -5
    },

    -- Shaman --
    [51387] = {  -- Lightning Strike rk 1
      modifiedBuffName = "Lightning Shield",
      stackChange = -1
    },
    [52420] = {  -- Lightning Strike rk 2
      modifiedBuffName = "Lightning Shield",
      stackChange = -1
    },
    [52422] = {  -- Lightning Strike rk 3
      modifiedBuffName = "Lightning Shield",
      stackChange = -1
    },

    -- Druid --
    [5176] = {  -- Wrath rk 1
      modifiedBuffName = "Natural Boon",
      stackChange = -1
    },
    [5177] = {  -- Wrath rk 2
      modifiedBuffName = "Natural Boon",
      stackChange = -1
    },
    [5178] = {  -- Wrath rk 3
      modifiedBuffName = "Natural Boon",
      stackChange = -1
    },
    [5179] = {  -- Wrath rk 4
      modifiedBuffName = "Natural Boon",
      stackChange = -1
    },
    [5180] = {  -- Wrath rk 5
      modifiedBuffName = "Natural Boon",
      stackChange = -1
    },
    [6780] = {  -- Wrath rk 6
      modifiedBuffName = "Natural Boon",
      stackChange = -1
    },
    [8905] = {  -- Wrath rk 7
      modifiedBuffName = "Natural Boon",
      stackChange = -1
    },
    [9912] = {  -- Wrath rk 8
      modifiedBuffName = "Natural Boon",
      stackChange = -1
    },
    [45967] = {  -- Wrath rk 9
      modifiedBuffName = "Natural Boon",
      stackChange = -1
    },
    [2912] = {  -- Starfire rk 1
      modifiedBuffName = "Astral Boon",
      stackChange = -1
    },
    [8949] = {  -- Starfire rk 2
      modifiedBuffName = "Astral Boon",
      stackChange = -1
    },
    [8950] = {  -- Starfire rk 3
      modifiedBuffName = "Astral Boon",
      stackChange = -1
    },
    [8951] = {  -- Starfire rk 4
      modifiedBuffName = "Astral Boon",
      stackChange = -1
    },
    [9875] = {  -- Starfire rk 5
      modifiedBuffName = "Astral Boon",
      stackChange = -1
    },
    [9876] = {  -- Starfire rk 6
      modifiedBuffName = "Astral Boon",
      stackChange = -1
    },
    [25298] = {  -- Starfire rk 7
      modifiedBuffName = "Astral Boon",
      stackChange = -1
    },
  }
}
_G["DoiteBuffData"] = DoiteBuffData
