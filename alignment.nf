#! /usr/bin/env nextflow
// usage : ./alignment.nf --input_folder input/ --cpu 8 --mem 32 --ref hg19.fasta --RG "PL:ILLUMINA"
/*
vim: syntax=groovy
-*- mode: groovy;-*- */

// requirement:
// - samtools
// - samblaster
// - sambamba

//default values
params.help         = null
params.input_folder = '.'
params.fasta_ref    = 'hg19.fasta'
params.cpu          = 8
params.mem          = 32
params.mem_sambamba = 1
params.RG           = "PL:ILLUMINA"
params.fastq_ext    = "fastq.gz"
params.suffix1      = "_1"
params.suffix2      = "_2"
params.out_folder   = "results_alignment"
params.intervals    = ""
params.GATK_bundle       = "bundle"
params.GATK_folder  = "."
params.indel_realignment = "false"
params.recalibration = "false"
params.js           = "k8"
params.postaltjs    = "bwa-postalt.js"
params.alt          = "false"

if (params.help) {
    log.info ''
    log.info '-------------------------------------------------------------'
    log.info 'NEXTFLOW WHOLE EXOME/GENOME ALIGNMENT OR REALIGNMENT PIPELINE'
    log.info '-------------------------------------------------------------'
    log.info ''
    log.info 'Usage: '
    log.info 'nextflow run alignment.nf --input_folder input/ --fasta_ref hg19.fasta [--cpu 8] [--mem 32] [--RG "PL:ILLUMINA"] [--fastq_ext fastq.gz] [--suffix1 _1] [--suffix2 _2] [--out_folder output/]'
    log.info ''
    log.info 'Mandatory arguments:'
    log.info '    --input_folder   FOLDER                  Folder containing BAM or fastq files to be aligned.'
    log.info '    --fasta_ref          FILE                    Reference fasta file (with index).'
    log.info 'Optional arguments:'
    log.info '    --indel_realignment                    Performs local indel realignment (default: no).'
    log.info '    --cpu          INTEGER                 Number of cpu used by bwa mem and sambamba (default: 8).'
    log.info '    --mem          INTEGER                 Size of memory used by sambamba (in GB) (default: 32).'
    log.info '    --RG           STRING                  Samtools read group specification with "\t" between fields.'
    log.info '                                           e.g. --RG "PL:ILLUMINA\tDS:custom_read_group".'
    log.info '                                           Default: "ID:bam_file_name\tSM:bam_file_name".'
    log.info '    --fastq_ext      STRING                Extension of fastq files (default : fastq.gz)'
    log.info '    --suffix1        STRING                Suffix of fastq files 1 (default : _1)'
    log.info '    --suffix2        STRING                Suffix of fastq files 2 (default : _2)'
    log.info '    --out_folder     STRING                Output folder (default: results_alignment).'
    log.info ''
    exit 1
}

//read files
fastaall=params.fasta_ref+'*'
fasta_refs = file( fastaall )
println fasta_refs
mode = 'fastq'
if (file(params.input_folder).listFiles().findAll { it.name ==~ /.*${params.fastq_ext}/ }.size() > 0){
    println "fastq files found, proceed with alignment"
}else{
    if (file(params.input_folder).listFiles().findAll { it.name ==~ /.*bam/ }.size() > 0){
        println "BAM files found, proceed with realignment"; mode ='bam'; files = Channel.fromPath( params.input_folder+'/*.bam' )
    }else{
        println "ERROR: input folder contains no fastq nor BAM files"; System.exit(0)
    }
}

if(mode=='bam'){
    process bam_realignment {
        cpus params.cpu
        memory params.mem+'G'
        tag { file_tag }
        
        input:
        file infile from files
        file fasta_refs
     
        output:
	set val(file_tag), file("*_tmp.bam") into bam_files, bam_files2
	set val(file_tag), file("*_tmp.bam.bai") into bai_files, bai_files2

        script:
	if(params.alt=="false"){
	  ignorealt='-j'
	  postalt=''
	}else{
	  ignorealt=''
	  postalt=params.js+' '+params.postaltjs+' '+params.fasta_ref+'.alt |'
	}
	println ignorealt
	println postalt
        shell:
        file_tag = infile.baseName
        '''
        set -o pipefail
        samtools collate -uOn 128 !{file_tag}.bam tmp_!{file_tag} | samtools fastq - | bwa mem $ignorealt -M -t!{task.cpus} -R "@RG\\tID:!{file_tag}\\tSM:!{file_tag}\\t!{params.RG}" -p !{params.fasta_ref} - | $postalt samblaster --addMateTags | sambamba view -S -f bam -l 0 /dev/stdin | sambamba sort -t !{task.cpus} -m !{params.mem_sambamba}G --tmpdir=!{file_tag}_tmp -o !{file_tag}_tmp.bam /dev/stdin
        '''
    }
}
if(mode=='fastq'){
    println "fastq mode"
    keys1 = file(params.input_folder).listFiles().findAll { it.name ==~ /.*${params.suffix1}.${params.fastq_ext}/ }.collect { it.getName() }
                                                                                                               .collect { it.replace("${params.suffix1}.${params.fastq_ext}",'') }
    keys2 = file(params.input_folder).listFiles().findAll { it.name ==~ /.*${params.suffix2}.${params.fastq_ext}/ }.collect { it.getName() }
                                                                                                               .collect { it.replace("${params.suffix2}.${params.fastq_ext}",'') }
    if ( !(keys1.containsAll(keys2)) || !(keys2.containsAll(keys1)) ) {println "\n ERROR : There is at least one fastq without its mate, please check your fastq files."; System.exit(0)}

    println keys1

    // Gather files ending with _1 suffix
    reads1 = Channel
    .fromPath( params.input_folder+'/*'+params.suffix1+'.'+params.fastq_ext )
    .map {  path -> [ path.name.replace("${params.suffix1}.${params.fastq_ext}",""), path ] }

    // Gather files ending with _2 suffix
    reads2 = Channel
    .fromPath( params.input_folder+'/*'+params.suffix2+'.'+params.fastq_ext )
    .map {  path -> [ path.name.replace("${params.suffix2}.${params.fastq_ext}",""), path ] }

    // Match the pairs on two channels having the same 'key' (name) and emit a new pair containing the expected files
    readPairs = reads1
    .phase(reads2)
    .map { pair1, pair2 -> [ pair1[1], pair2[1] ] }

    println reads1
        
    process fastq_alignment {

        cpus params.cpu
        memory params.mem+'GB'    
        tag { file_tag }
        
        input:
        file pair from readPairs
        file fasta_refs
            
        output:
        set val(file_tag), file('${file_tag}_tmp.bam') into bam_files, bam_files2
	set val(file_tag), file('${file_tag}_tmp.bam.bai') into bai_files, bai_files2

        shell:
        file_tag = pair[0].name.replace("${params.suffix1}.${params.fastq_ext}","")
        '''
        set -o pipefail
        bwa mem -M -t!{task.cpus} -R "@RG\\tID:!{file_tag}\\tSM:!{file_tag}\\t!{params.RG}" !{params.fasta_ref} !{pair[0]} !{pair[1]} | samblaster --addMateTags | sambamba view -S -f bam -l 0 /dev/stdin | sambamba sort -t !{task.cpus} -m !{params.mem}G --tmpdir=!{file_tag}_tmp -o !{file_tag}_tmp.bam /dev/stdin
        '''
    }
}

// for alt contigs: k8 bwa-postalt.js chr19_chr19_KI270866v1_alt.fasta.alt altalt.sam > altalt_postalt.sam


if(params.indel_realignment != "false"){
        // Local realignment around indels
        process indel_realignment {
            cpus params.cpu
            memory params.mem+'G'
            tag { file_tag }
            input:
	    set val(file_tag), file("${file_tag}_tmp.bam") from bam_files
	    set val(file_tag), file("${file_tag}_tmp.bam.bai") from bai_files
            output:
            set val(file_tag), file("${file_tag}_target_intervals.list") into indel_realign_target_files
            set val(file_tag), file("${file_tag}_tmp.bam") into bam_files3
	    set val(file_tag), file("${file_tag}_tmp.bai") into bai_files3
            shell:
            '''
	    indelsvcf=`ls !{params.GATK_bundle}/*indels*.vcf`
	    for ll in $indelsvcf; do knowncom=$knowncom' -known '$ll; done
            java -jar !{params.GATK_folder}/GenomeAnalysisTK.jar -T RealignerTargetCreator -nt !{params.cpu} -R !{params.fasta_ref} -I !{file_tag}_tmp.bam $knowncom -o !{file_tag}_target_intervals.list
            java -jar !{params.GATK_folder}/GenomeAnalysisTK.jar -T IndelRealigner -R !{params.fasta_ref} -I !{file_tag}_tmp.bam -targetIntervals !{file_tag}_target_intervals.list $knowncom -o !{file_tag}_tmp2.bam
            rm !{file_tag}_tmp.bam
	    rm !{file_tag}_tmp.bai
            mv !{file_tag}_tmp2.bam !{file_tag}_tmp.bam
	    mv !{file_tag}_tmp2.bai !{file_tag}_tmp.bai
            '''
        }
}else{
    process no_indel_realignment {
        cpus '1'
        memory '100M'
        tag { file_tag }
        
        input:
        set val(file_tag), file("${file_tag}_tmp.bam") from bam_files
	set val(file_tag), file("${file_tag}_tmp.bam.bai") from bai_files
        output:
        set val(file_tag), file("${file_tag}_tmp.bam") into bam_files3
	set val(file_tag), file("${file_tag}_tmp.bai") into bai_files3
	shell:
        '''
	mv !{file_tag}_tmp.bam.bai !{file_tag}_tmp.bai
        '''
    }
}

if(params.recalibration!= "false"){
// base quality score recalibration
process base_quality_score_recalibration {
    cpus params.cpu
    memory params.mem+'G'
    tag { file_tag }
        
    input:
    set val(file_tag), file("${file_tag}_tmp.bam") from bam_files3
    set val(file_tag), file("${file_tag}_tmp.bai") from bai_files3
    output:
    set val(file_tag), file("${file_tag}_recal.table") into recal_table_files
    set val(file_tag), file("${file_tag}_post_recal.table") into recal_table_post_files
    set val(file_tag), file("${file_tag}_recalibration_plots.pdf") into recal_plots_files
    set val(file_tag), file("${file_tag}_recal.bam") into recal_bam_files
    set val(file_tag), file("${file_tag}_recal.bai") into recal_bai_files
    publishDir params.out_folder, mode: 'move'
    shell:
    '''
    indelsvcf=`ls !{params.GATK_bundle}/*indels*.vcf`
    dbsnpvcfs=(`ls !{params.GATK_bundle}/*dbsnp*.vcf`)
    dbsnpvcf=${dbsnpvcfs[@]:(-1)}
    for ll in $indelsvcf; do knownSitescom=$knownSitescom' -knownSites '$ll; done
    knownSitescom=$knownSitescom' -knownSites '$dbsnpvcf
    java -jar !{params.GATK_folder}/GenomeAnalysisTK.jar -T BaseRecalibrator -nct !{params.cpu} -R !{params.fasta_ref} -I !{file_tag}_tmp.bam $knownSitescom -L !{params.intervals} -o !{file_tag}_recal.table
    java -jar !{params.GATK_folder}/GenomeAnalysisTK.jar -T BaseRecalibrator -nct !{params.cpu} -R !{params.fasta_ref} -I !{file_tag}_tmp.bam $knownSitescom -BQSR !{file_tag}_recal.table -L !{params.intervals} -o !{file_tag}_post_recal.table		
    java -jar !{params.GATK_folder}/GenomeAnalysisTK.jar -T AnalyzeCovariates -R !{params.fasta_ref} -before !{file_tag}_recal.table -after !{file_tag}_post_recal.table -plots !{file_tag}_recalibration_plots.pdf	
    java -jar !{params.GATK_folder}/GenomeAnalysisTK.jar -T PrintReads -nct !{params.cpu} -R !{params.fasta_ref} -I !{file_tag}_tmp.bam -BQSR !{file_tag}_recal.table -L !{params.intervals} -o !{file_tag}_recal.bam	
    rm !{file_tag}_tmp.bam
    '''
}
}else{
  process no_recalibration {
        cpus '1'
        memory '100M'
        tag { file_tag }
        
        input:
        set val(file_tag), file("${file_tag}_tmp.bam") from bam_files3
	set val(file_tag), file("${file_tag}_tmp.bai") from bai_files3
        output:
        set val(file_tag), file("${file_tag}_norecal.bam") into norecal_bam_files
	set val(file_tag), file("${file_tag}_norecal.bai") into norecal_bai_files
	publishDir params.out_folder, mode: 'move'
	shell:
        '''
	mv !{file_tag}_tmp.bam !{file_tag}_norecal.bam
	mv !{file_tag}_tmp.bai !{file_tag}_norecal.bai
        '''
    }

}
