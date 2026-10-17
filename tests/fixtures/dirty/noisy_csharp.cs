using System;
using System.Collections.Generic;
using System.Linq;

public class SessionHandler
{
    public bool HandleSession(User user, Config config)
    {
        // Complex inline boolean conditional without semantic abstraction
        if (user.IsActive && config.AllowAccess || user.IsSuperAdmin && !config.Maintenance)
        {
            Console.WriteLine("ACTIVE");
        }

        // Deep nesting level 3 (> 2) inside function
        if (user != null)
        {
            for (int i = 0; i < user.Items.Count; i++)
            {
                if (user.Items[i].Valid)
                {
                    Console.WriteLine(user.Items[i].Name);
                }
            }
        }

        // Long inline lambda (> 80 chars)
        var mapped = user.Items.Select(it => new { Id = it.Id, Name = it.Name, Score = it.Score * 1.5, Active = it.Status == "ACTIVE" }).ToList();

        // Unnecessary else block after early return
        if (user.IsBlocked)
        {
            return false;
        }
        else
        {
            Console.WriteLine("Not blocked");
        }

        return user.IsActive ? true : false;
    }
}
