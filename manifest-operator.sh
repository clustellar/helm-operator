#!/bin/bash

STATUS_MET="dependencies-met"
STATUS_MIS="missing-dependency"
STATUS_INS="ready-to-install"
STATUS_UPG="ready-to-upgrade"
STATUS_REM="marked-for-removal"
STATUS_PUR="marked-for-purge"

cachedir=/var/cache/helm
gitdir=/var/cache/git
dependencyfile="dependencies.yaml"

_git_checkout() {
  local repodir="$1"
  local branch="$2"
  local repodir="$3"

  # checkout helm chart repo
  if [ -d $repodir ]; then
    owd=$(pwd)
    cd $repodir
    git checkout $branch
    git pull
    cd $owd
  else
    git clone --branch $branch $repo $repodir
  fi
}

_get_values_for_chart() {

}

# check dependencies for all manifest charts
for manifest in kubectl get manifests; do
  for chart in kubectl get manifest $manifest | jq '.spec.charts'; do
    local repo=$(kubectl get manifest $manifest -o jsonpath=".spec.charts[$chart].repo")
    local branch=$(kubectl get manifest $manifest -o jsonpath=".spec.charts[$chart].branch")
    local release=$(kubectl get manifest $manifest -o jsonpath=".spec.charts[$chart].release")
    local repodir=$gitdir/$release
    local status=''

    _git_checkout $repo $branch $repodir

    # check dependencies
    if [ -f $repodir/$dependencyfile ]; then
      if check-dependencies $repodir/$dependencyfile; then
        status="$STATUS_MET"
      else
        status="$STATUS_MIS"
      fi      
    else
      echo "WARN: No dependency file found at '$repodir/$dependencyfile', marking for install anyway"
    fi

    if [ "$status" == "$STATUS_MET" ]; then
      helm_line=$(helm list $chart | grep $chart)

      if [ "$helm_line" != "" ]; then
        if echo "$helm_line" | grep "DEPLOYED"; then
          status="$STATUS_UPG"
        else 
          if echo "$helm_line" | grep -e "FAILED|DELETED"; then
            status="$STATUS_PUR"
          else
            status="$STATUS_REM"
          fi
        fi
      else
        status="$STATUS_INS"
      fi
    fi

    # update chart status in kubernetes crd with $status
    update_chart_status $chart $status
  done
done


# perform helm action for all charts in manifest
for manifest in kubectl get manifests; do
  for chart in kubectl get manifest $manifest | jq '.spec.charts'; do
    local parentvalues = $cachedir/$chart-parent-values.json
    local chartvalues = $cachedir/$chart-values.json
    local parent_manifest = $(cat $chartfile | jq '.spec.parent_manifest')
    local status=$(kubectl get manifest $manifest -o jsonpath=".spec.charts[$chart].status")

    if [ "$parent_manifest" != "" ]; then
      # add the global values from the parent
      kubectl get manifest $parent_manifest -o jsonpath=".spec.globals" > $parentvalues

      # add any values for this chart from the parent
      kubectl get manifest $parent_manifest -o jsonpath=".spec.charts[$chart].values" >> $parentvalues
    fi

    # add the global values from the chart
    kubectl get manifest $manifest -o jsonpath=".spec.globals" > $chartvalues

    # add any values for this chart
    kubectl get manifest $manifest -o jsonpath=".spec.charts[$chart].values" >> $chartvalues

    case "$status" in
      ready-for-install)
        helm install -f $parentvalues -f $chartvalues --name $chart --namespace
        ;;
      ready-for-upgrade)
        helm upgrade -f $parentvalues -f $chartvalues $chart
        ;;
      marked-for-removal)
        helm del $chart
        ;;
      marked-for-purge)
        helm del --purge $chart
      *)
        echo "[WARN] Chart '$chart' has an invalid status of '$status'."
        ;;
    esac
  done
done
