def age: (now - (.createdAt|fromdate))/3600;
def current_checks:
  ((.headRefOid // "") | tostring | ascii_downcase) as $head |
  [ (.statusCheckRollup // [])[]?
    | select(
        ((.headSha // .head_sha // .commit.oid // "") | tostring | ascii_downcase) as $ch
        | ($ch == "" or $head == "" or $ch == $head)
      )
  ]
  | reduce .[] as $c ({};
      (($c.name // $c.context // "") | tostring) as $k |
      if $k == "" then . + { ("__anon_" + (length|tostring)): $c }
      else
        (.[$k]) as $prev |
        if $prev == null then . + { ($k): $c }
        else
          (($prev.startedAt // $prev.completedAt // $prev.createdAt // "") | tostring) as $pt |
          (($c.startedAt // $c.completedAt // $c.createdAt // "") | tostring) as $ct |
          if ($ct != "" and $pt != "" and $ct < $pt) then .
          else . + { ($k): $c }
          end
        end
      end
    )
  | [ .[] ];
def fails: [current_checks[]|select((.conclusion // .state // "" | ascii_upcase) == "FAILURE")|.name//.context];
def running:
  [current_checks[]|select(
    ((.status // "" | ascii_upcase) as $s | ($s == "IN_PROGRESS" or $s == "QUEUED" or $s == "PENDING" or $s == "WAITING" or $s == "REQUESTED"))
    or ((.state // "" | ascii_upcase) == "PENDING")
    or (((.status // "") != "") and ((.status // "" | ascii_upcase) != "COMPLETED") and ((.conclusion // "") == ""))
  )]|length;
def sharedgate: ["fast-checks","fast-checks-required","audit","audit-required","test","verified"];
def stale_red: (fails|length)>0 and ([fails[]|select(.|IN(sharedgate[]))]|length)==(fails|length);
def price:
  age as $age | (fails|length) as $f | running as $r | .mergeStateStatus as $ms |
  (if .isDraft then 0.10
   elif ($f==0 and $r>0 and $ms!="DIRTY") then 0.85
   elif (.mergeStateStatus=="MERGEABLE" or .mergeStateStatus=="CLEAN") then 0.92
   elif ($ms=="DIRTY" and $f==0) then 0.60
   elif ($ms=="DIRTY" and stale_red) then 0.50
   elif ($ms=="DIRTY") then 0.28
   elif ($ms=="BLOCKED" and $f==0 and $r>0) then 0.85
   elif ($ms=="BLOCKED" and $f==0) then 0.80
   elif ($ms=="BEHIND" and $f==0) then 0.75
   elif ($f==0) then 0.80
   elif (stale_red) then 0.55
   elif ($f>=5) then 0.18
   elif ($f>0) then 0.30
   else 0.50 end) as $base |
  (if ($ms=="DIRTY" and $age>8) then ($base*0.6) else $base end);
def action:
  age as $age | (fails|length) as $f | running as $r | .mergeStateStatus as $ms |
  (if .isDraft then "un-draft"
   elif ($f==0 and $r>0 and $ms!="DIRTY") then "wait-CI"
   elif ($ms=="MERGEABLE" or $ms=="CLEAN") then "MERGE-NOW"
   elif ($ms=="DIRTY" and $f==0 and $age>8) then "REBASE (reaper imminent)"
   elif ($ms=="DIRTY" and $f==0) then "rebase"
   elif ($ms=="DIRTY" and stale_red) then "rebase+rerun(stale)"
   elif ($ms=="DIRTY" and $age>8) then "CUT? resolve-or-close"
   elif ($ms=="DIRTY") then "resolve-conflict"
   elif ($ms=="BEHIND" and $f==0) then "rebase"
   elif ($ms=="BLOCKED" and $f==0) then "merge-candidate"
   elif ($f==0) then "merge-candidate"
   elif (stale_red) then "rebase+rerun(stale)"
   elif ($f>=5) then "CUT? deep-red"
   else "fix-own-red" end);
