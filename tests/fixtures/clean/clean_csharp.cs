using System;
using System.Collections.Generic;
using System.Linq;

public class CleanSession
{
    private static bool CanAccess(User user, Config config)
    {
        if (user.IsSuperAdmin && !config.Maintenance)
        {
            return true;
        }
        return user.IsActive && config.AllowAccess;
    }

    private static ScoredItem ToScoredItem(Item it)
    {
        return new ScoredItem(it.Id, it.Score * 1.5);
    }

    public static bool HandleSession(User user, Config config)
    {
        if (!CanAccess(user, config))
        {
            return false;
        }

        var scores = user.Items.Select(ToScoredItem).ToList();
        return true;
    }
}
