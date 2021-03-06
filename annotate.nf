#!/usr/bin/env nextflow

/*
vim: syntax=groovy
-*- mode: groovy;-*-
kate: syntax groovy; space-indent on; indent-width 2;
================================================================================
=                                 S  A  R  E  K                                =
================================================================================
 New Germline (+ Somatic) Analysis Workflow. Started March 2016.
--------------------------------------------------------------------------------
 @Authors
 Sebastian DiLorenzo <sebastian.dilorenzo@bils.se> [@Sebastian-D]
 Jesper Eisfeldt <jesper.eisfeldt@scilifelab.se> [@J35P312]
 Phil Ewels <phil.ewels@scilifelab.se> [@ewels]
 Maxime Garcia <maxime.garcia@scilifelab.se> [@MaxUlysse]
 Szilveszter Juhos <szilveszter.juhos@scilifelab.se> [@szilvajuhos]
 Max Käller <max.kaller@scilifelab.se> [@gulfshores]
 Malin Larsson <malin.larsson@scilifelab.se> [@malinlarsson]
 Marcel Martin <marcel.martin@scilifelab.se> [@marcelm]
 Björn Nystedt <bjorn.nystedt@scilifelab.se> [@bjornnystedt]
 Pall Olason <pall.olason@scilifelab.se> [@pallolason]
 Pelin Sahlén <pelin.akan@scilifelab.se> [@pelinakan]
--------------------------------------------------------------------------------
 @Homepage
 http://opensource.scilifelab.se/projects/sarek/
--------------------------------------------------------------------------------
 @Documentation
 https://github.com/SciLifeLab/Sarek/README.md
--------------------------------------------------------------------------------
 Processes overview
 - RunBcftoolsStats - Run BCFTools stats on vcf before annotation
 - RunSnpeff - Run snpEff for annotation of vcf files
 - RunVEP - Run VEP for annotation of vcf files
================================================================================
=                           C O N F I G U R A T I O N                          =
================================================================================
*/

version = '1.3'

// Check that Nextflow version is up to date enough
// try / throw / catch works for NF versions < 0.25 when this was implemented
nf_required_version = '0.25.0'
try {
    if( ! nextflow.version.matches(">= ${nf_required_version}") ){
        throw GroovyException('Nextflow version too old')
    }
} catch (all) {
    log.error "====================================================\n" +
              "  Nextflow version ${nf_required_version} required! You are running v${workflow.nextflow.version}.\n" +
              "  Pipeline execution will continue, but things may break.\n" +
              "  Please update Nextflow.\n" +
              "============================================================"
}

if (params.help) exit 0, helpMessage()
if (params.version) exit 0, versionMessage()
if (!isAllowedParams(params)) exit 1, "params unknown, see --help for more information"
if (!checkUppmaxProject()) exit 1, "No UPPMAX project ID found! Use --project <UPPMAX Project ID>"

// Default params:
// Such params are overridden by command line or configuration definitions

// No tools to annotate
params.annotateTools = ''
// No vcf to annotare
params.annotateVCF = ''
// Reports are generated
params.noReports = false
// Run Sarek in onlyQC mode
params.onlyQC = false
// outDir is current directory
params.outDir = baseDir
// Step is annotate
step = 'annotate'
// Not testing
params.test = ''
// No tools to be used
params.tools = ''
// Params are defined in config files
params.containerPath = ''
params.repository = ''
params.tag = ''

tools = params.tools ? params.tools.split(',').collect{it.trim().toLowerCase()} : []
annotateTools = params.annotateTools ? params.annotateTools.split(',').collect{it.trim().toLowerCase()} : []
annotateVCF = params.annotateVCF ? params.annotateVCF.split(',').collect{it.trim()} : []

directoryMap = defineDirectoryMap()
toolList = defineToolList()
reports = !params.noReports
onlyQC = params.onlyQC
verbose = params.verbose

if (!checkParameterList(tools,toolList)) exit 1, 'Unknown tool(s), see --help for more information'

/*
================================================================================
=                               P R O C E S S E S                              =
================================================================================
*/

startMessage()

vcfToAnnotate = Channel.create()
vcfNotToAnnotate = Channel.create()

if (step == 'annotate' && annotateVCF == []) {
  Channel.empty().mix(
    Channel.fromPath("${params.outDir}/VariantCalling/HaplotypeCaller/*.vcf.gz")
      .flatten().map{vcf -> ['haplotypecaller',vcf]},
    Channel.fromPath("${params.outDir}/VariantCalling/Manta/*SV.vcf.gz")
      .flatten().map{vcf -> ['manta',vcf]},
    Channel.fromPath("${params.outDir}/VariantCalling/MuTect1/*.vcf.gz")
      .flatten().map{vcf -> ['mutect1',vcf]},
    Channel.fromPath("${params.outDir}/VariantCalling/MuTect2/*.vcf.gz")
      .flatten().map{vcf -> ['mutect2',vcf]},
    Channel.fromPath("${params.outDir}/VariantCalling/Strelka/*{somatic,variants}*.vcf.gz")
      .flatten().map{vcf -> ['strelka',vcf]}
  ).choice(vcfToAnnotate, vcfNotToAnnotate) { annotateTools == [] || (annotateTools != [] && it[0] in annotateTools) ? 0 : 1 }

} else if (step == 'annotate' && annotateTools == [] && annotateVCF != []) {
  list = ""
  annotateVCF.each{ list += ",${it}" }
  list = list.substring(1)
  if (StringUtils.countMatches("${list}", ",") == 0) vcfToAnnotate = Channel.fromPath("${list}")
    .map{vcf -> ['userspecified',vcf]}
  else vcfToAnnotate = Channel.fromPath("{$list}")
    .map{vcf -> ['userspecified',vcf]}

}else exit 1, "specify only tools or files to annotate, bot both"

vcfNotToAnnotate.close()

(vcfForBCFtools, vcfForSnpeff, vcfForVep) = vcfToAnnotate.into(3)

process RunBcftoolsStats {
  tag {vcf}

  publishDir "${params.outDir}/${directoryMap.bcftoolsStats}", mode: 'copy'

  input:
    set variantCaller, file(vcf) from vcfForBCFtools

  output:
    file ("${vcf.baseName}.bcf.tools.stats.out") into bcfReport

  when: reports

  script:
  """
  bcftools stats ${vcf} > ${vcf.baseName}.bcf.tools.stats.out
  """
}

if (verbose) bcfReport = bcfReport.view {
  "BCFTools stats report:\n\
  File  : [${it.fileName}]"
}

process RunSnpeff {
  tag {vcf}

  publishDir "${params.outDir}/${directoryMap.snpeff}", mode: 'copy'

  input:
    set variantCaller, file(vcf) from vcfForSnpeff
    val snpeffDb from Channel.value(params.genomes[params.genome].snpeffDb)

  output:
    set file("${vcf.baseName}.snpEff.ann.vcf"), file("${vcf.baseName}.snpEff.genes.txt"), file("${vcf.baseName}.snpEff.csv"), file("${vcf.baseName}.snpEff.summary.html") into snpeffReport

  when: 'snpeff' in tools

  script:
  """
  java -Xmx${task.memory.toGiga()}g \
  -jar \$SNPEFF_HOME/snpEff.jar \
  ${snpeffDb} \
  -csvStats ${vcf.baseName}.snpEff.csv \
  -nodownload \
  -cancer \
  -v \
  ${vcf} \
  > ${vcf.baseName}.snpEff.ann.vcf

  mv snpEff_summary.html ${vcf.baseName}.snpEff.summary.html
  """
}

if (verbose) snpeffReport = snpeffReport.view {
  "snpEff report:\n\
  File  : ${it.fileName}"
}

process RunVEP {
  tag {vcf}

  publishDir "${params.outDir}/${directoryMap.vep}", mode: 'copy'

  input:
    set variantCaller, file(vcf) from vcfForVep

  output:
    set file("${vcf.baseName}.vep.ann.vcf"), file("${vcf.baseName}.vep.summary.html") into vepReport

  when: 'vep' in tools

  script:
  genome = params.genome == 'smallGRCh37' ? 'GRCh37' : params.genome
  """
  vep \
  -i ${vcf} \
  -o ${vcf.baseName}.vep.ann.vcf \
  --stats_file ${vcf.baseName}.vep.summary.html \
  --cache \
  --everything \
  --filter_common \
  --format vcf \
  --offline \
  --pick \
  --fork ${task.cpus} \
  --total_length \
  --vcf
  """
}

if (verbose) vepReport = vepReport.view {
  "VEP report:\n\
  Files : ${it.fileName}"
}

/*
================================================================================
=                               F U N C T I O N S                              =
================================================================================
*/

def sarekMessage() {
  // Display Sarek message
  log.info "Sarek ~ ${version} - " + this.grabRevision() + (workflow.commitId ? " [${workflow.commitId}]" : "")
}

def checkParameterExistence(it, list) {
  // Check parameter existence
  if (!list.contains(it)) {
    println("Unknown parameter: ${it}")
    return false
  }
  return true
}

def checkParameterList(list, realList) {
  // Loop through all parameters to check their existence and spelling
  return list.every{ checkParameterExistence(it, realList) }
}

def checkParamReturnFile(item) {
  params."${item}" = params.genomes[params.genome]."${item}"
  return file(params."${item}")
}

def checkParams(it) {
  // Check if params is in this given list
  return it in [
    'ac-loci',
    'acLoci',
    'annotate-tools',
    'annotate-VCF',
    'annotateTools',
    'annotateVCF',
    'build',
    'bwa-index',
    'bwaIndex',
    'call-name',
    'callName',
    'contact-mail',
    'contactMail',
    'container-path',
    'containerPath',
    'containers',
    'cosmic-index',
    'cosmic',
    'cosmicIndex',
    'dbsnp-index',
    'dbsnp',
    'docker',
    'genome_base',
    'genome-dict',
    'genome-file',
    'genome-index',
    'genome',
    'genomeDict',
    'genomeFile',
    'genomeIndex',
    'genomes',
    'help',
    'intervals',
    'known-indels-index',
    'known-indels',
    'knownIndels',
    'knownIndelsIndex',
    'max_cpus',
    'max_memory',
    'max_time',
    'no-BAMQC',
    'no-GVCF',
    'no-reports',
    'noBAMQC',
    'noGVCF',
    'noReports',
    'only-QC',
    'onlyQC',
    'out-dir',
    'outDir',
    'params',
    'project',
    'push',
    'repository',
    'run-time',
    'runTime',
    'sample-dir',
    'sample',
    'sampleDir',
    'single-CPUMem',
    'singleCPUMem',
    'singularity',
    'step',
    'tag',
    'test',
    'tools',
    'total-memory',
    'totalMemory',
    'vcflist',
    'verbose',
    'version']
}

def checkReferenceMap(referenceMap) {
  // Loop through all the references files to check their existence
  referenceMap.every {
    referenceFile, fileToCheck ->
    checkRefExistence(referenceFile, fileToCheck)
  }
}

def checkRefExistence(referenceFile, fileToCheck) {
  if (fileToCheck instanceof List) return fileToCheck.every{ checkRefExistence(referenceFile, it) }
  def f = file(fileToCheck)
  // this is an expanded wildcard: we can assume all files exist
  if (f instanceof List && f.size() > 0) return true
  else if (!f.exists()) {
    log.info  "Missing references: ${referenceFile} ${fileToCheck}"
    return false
  }
  return true
}

def checkUppmaxProject() {
  // check if UPPMAX project number is specified
  return !(workflow.profile == 'slurm' && !params.project)
}

def defineDirectoryMap() {
  return [
    'bcftoolsStats'    : 'Reports/BCFToolsStats',
    'snpeff'           : 'Annotation/SnpEff',
    'vep'              : 'Annotation/VEP'
  ]
}

def defineStepList() {
  return [
    'annotate'
  ]
}

def defineToolList() {
  return [
    'snpeff',
    'vep'
  ]
}

def grabRevision() {
  // Return the same string executed from github or not
  return workflow.revision ?: workflow.commitId ?: workflow.scriptId.substring(0,10)
}

def helpMessage() {
  // Display help message
  this.sarekMessage()
  log.info "    Usage:"
  log.info "       nextflow run SciLifeLab/Sarek --sample <file.tsv> [--step STEP] [--tools TOOL[,TOOL]] --genome <Genome>"
  log.info "       nextflow run SciLifeLab/Sarek --sampleDir <Directory> [--step STEP] [--tools TOOL[,TOOL]] --genome <Genome>"
  log.info "       nextflow run SciLifeLab/Sarek --test [--step STEP] [--tools TOOL[,TOOL]] --genome <Genome>"
  log.info "    --step"
  log.info "       Option to start workflow"
  log.info "       Possible values are:"
  log.info "         annotate (will annotate Variant Calling output."
  log.info "         By default it will try to annotate all available vcfs."
  log.info "         Use with --annotateTools or --annotateVCF to specify what to annotate"
  log.info "    --noReports"
  log.info "       Disable QC tools and MultiQC to generate a HTML report"
  log.info "    --tools"
  log.info "       Option to configure which tools to use in the workflow."
  log.info "         Different tools to be separated by commas."
  log.info "       Possible values are:"
  log.info "         snpeff (use snpEff for Annotation of Variants)"
  log.info "         vep (use VEP for Annotation of Variants)"
  log.info "    --annotateTools"
  log.info "       Option to configure which tools to annotate."
  log.info "         Different tools to be separated by commas."
  log.info "       Possible values are:"
  log.info "         haplotypecaller (Annotate HaplotypeCaller output)"
  log.info "         manta (Annotate Manta output)"
  log.info "         mutect1 (Annotate MuTect1 output)"
  log.info "         mutect2 (Annotate MuTect2 output)"
  log.info "         strelka (Annotate Strelka output)"
  log.info "    --annotateVCF"
  log.info "       Option to configure which vcf to annotate."
  log.info "         Different vcf to be separated by commas."
  log.info "    --genome <Genome>"
  log.info "       Use a specific genome version."
  log.info "       Possible values are:"
  log.info "         GRCh37"
  log.info "         GRCh38 (Default)"
  log.info "         smallGRCh37 (Use a small reference (Tests only))"
  log.info "    --onlyQC"
  log.info "       Run only QC tools and gather reports"
  log.info "    --help"
  log.info "       you're reading it"
  log.info "    --verbose"
  log.info "       Adds more verbosity to workflow"
  log.info "    --version"
  log.info "       displays version number"
}

def isAllowedParams(params) {
  // Compare params to list of verified params
  final test = true
  params.each{
    if (!checkParams(it.toString().split('=')[0])) {
      println "params ${it.toString().split('=')[0]} is unknown"
      test = false
    }
  }
  return test
}

def minimalInformationMessage() {
  // Minimal information message
  log.info "Command Line: " + workflow.commandLine
  log.info "Profile     : " + workflow.profile
  log.info "Project Dir : " + workflow.projectDir
  log.info "Launch Dir  : " + workflow.launchDir
  log.info "Work Dir    : " + workflow.workDir
  log.info "Out Dir     : " + params.outDir
  if (step != 'annotate') log.info "TSV file    : ${tsvFile}"
  log.info "Genome      : " + params.genome
  log.info "Genome_base : " + params.genome_base
  log.info "Step        : " + step
  if (tools) log.info "Tools       : " + tools.join(', ')
  if (annotateTools) log.info "Annotate on : " + annotateTools.join(', ')
  if (annotateVCF) log.info "VCF files   : " +annotateVCF.join(',\n    ')
  log.info "Containers  :"
  if (params.repository) log.info "  Repository   : ${params.repository}"
  else log.info "  ContainerPath: " + params.containerPath
  log.info "  Tag          : " + params.tag
  log.info "Reference files used:"
  log.info "  snpeffDb    :\n\t" + params.genomes[params.genome].snpeffDb
}

def nextflowMessage() {
  // Nextflow message (version + build)
  log.info "N E X T F L O W  ~  version ${workflow.nextflow.version} ${workflow.nextflow.build}"
}

def startMessage() {
  // Display start message
  this.sarekMessage()
  this.minimalInformationMessage()
}

def versionMessage() {
  // Display version message
  log.info "Sarek"
  log.info "  version   : " + version
  log.info workflow.commitId ? "Git info    : ${workflow.repository} - ${workflow.revision} [${workflow.commitId}]" : "  revision  : " + this.grabRevision()
}

workflow.onComplete {
  // Display complete message
  this.nextflowMessage()
  this.sarekMessage()
  this.minimalInformationMessage()
  log.info "Completed at: " + workflow.complete
  log.info "Duration    : " + workflow.duration
  log.info "Success     : " + workflow.success
  log.info "Exit status : " + workflow.exitStatus
  log.info "Error report: " + (workflow.errorReport ?: '-')
}

workflow.onError {
  // Display error message
  this.nextflowMessage()
  this.sarekMessage()
  log.info "Workflow execution stopped with the following message:"
  log.info "  " + workflow.errorMessage
}
